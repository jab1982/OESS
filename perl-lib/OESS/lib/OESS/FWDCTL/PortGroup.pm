#!/usr/bin/perl
#------ NDDI OESS Port Group 
##-----
##----- $HeadURL:
##----- $Id:
##-----
##---------------------------------------------------------------------
##
## Copyright 2013 Trustees of Indiana University
##
##   Licensed under the Apache License, Version 2.0 (the "License");
##  you may not use this file except in compliance with the License.
##   You may obtain a copy of the License at
##
##       http://www.apache.org/licenses/LICENSE-2.0
##
##   Unless required by applicable law or agreed to in writing, software
##   distributed under the License is distributed on an "AS IS" BASIS,
##   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
##   See the License for the specific language governing permissions and
##   limitations under the License.
#
use strict;
use warnings;

###############################################################################
package OESS::FWDCTL::PortGroup;

use Log::Log4perl;
use OESS::Database;
use OESS::DBus;
use OESS::FWDCTL::Master;

$| = 1;

my $db   = new OESS::Database();

sub _log {                                                                                                                                              
    my $string = shift;
    my $logger = Log::Log4perl->get_logger("OESS.FWDCTL.PORTGROUP")->warn($string);
}

sub portgroup_check_if_interface_belongs{
    my $port_name = shift;
    my $node_name = shift;
    
    _log("port_name = $port_name and node_name = $node_name");

    if ( !$db ) {
    	_log("Unable to connect to database.");
	    return -1;
    }
    # If interface is part of a port group, returns interface_id, name and priority 
    return ($db->query_pgroup(port_name => $port_name, node_name => $node_name ));
}

sub portgroup_run{
    my $flapping_interface = shift;
    my $port_status = shift;
    $port_status = ($port_status == 1) ? 1 : 0;
    
    _log("interface_id = $flapping_interface->{'name'} and port_status = $port_status");

    my $current_active = _get_current_active($flapping_interface->{'pgroup_id'});

    if ($port_status == 1){
        # $port_status == 1 means it was down now it is UP
        # If the flapping port has better priority then the current active, migrate to the flapping port
        # If there is not current active ($current_active == 0), migrate to the flapping port
        # if the flapping port has lower priority, ignores
	    if ($current_active != 0){
	    	if ($current_active->{'priority'} > $flapping_interface->{'priority'}){
	    		_migrate_to_new_port($current_active, $flapping_interface);
	    	}else{
	    		_log('Current active has better priority. Do nothing');
	    	}
	    }else{
	    	_log("No current_active. Activating $flapping_interface->{'name'}");
	    	my $last_active = _get_last_active($flapping_interface->{'pgroup_id'});
	        _migrate_to_new_port($last_active, $flapping_interface);
	    }
    }elsif ($port_status == 0){
        # $port_status == 0 means it was up now it is DOWN
        # if the flapping port was not the active port, ignores
        # if the flapping port was the active port, look for the next candidate
        # if there is no next candidate (all ports down), sets no active
	    if ($current_active == 0 || $current_active->{'interface_id'} != $flapping_interface->{'interface_id'}){
	    	_log("There is no current active port, or port $flapping_interface->{'name'} was not the active port. Do nothing"); 
	    }else{
	    	_log("Get the candidate to active");
	    	my $candidate_interface = _get_candidate_interface($flapping_interface->{'pgroup_id'});
	    	if (! defined $candidate_interface){
	    		_log("No candidate available. Do nothing.");
	    		$db->disable_current_active( pgroup_id => $flapping_interface->{'pgroup_id'});
	    	}else{ 
	    	    _migrate_to_new_port($flapping_interface, $candidate_interface);
	    	}
	    }
    }
}

sub _get_current_active{
    my $pgroup_id = shift;
    return ($db->get_current_active( pgroup_id => $pgroup_id ));
}

sub _get_last_active{
    my $pgroup_id = shift;
    return ($db->get_last_active( pgroup_id => $pgroup_id ));
}

sub _get_candidate_interface{
    my $pgroup_id = shift;
    return ($db->get_candidate_interface( pgroup_id => $pgroup_id ));
}

sub _migrate_to_new_port{
    my $old_port = shift;
    my $new_port = shift;

    _log("Migrate from $old_port->{'name'} to interface $new_port->{'name'} on pgroup_id $new_port->{'pgroup_id'}");
    my $res = _move_edge_interface_circuits($old_port->{'interface_id'},$new_port->{'interface_id'});
#    if ($res == 0){
#    	return 0;
#    }else{
        _log("Moved $res->{'moved_circuits'} circuits and Unmoved $res->{'unmoved_circuits'} circuits");
#    }

    _log("Changing the active columm to the new port");
    my $result = $db->set_new_active( pgroup_id => $new_port->{'pgroup_id'}, interface_id => $new_port->{'interface_id'});
    if ($result == 0){
	    _log("Error setting $new_port->{'name'} as active on pgroup table.");
    }
    _log("Change done");
}

sub _move_edge_interface_circuits{
    my $orig_interface_id  = shift;
    my $new_interface_id   = shift;

    _log("$orig_interface_id and $new_interface_id");

    my $circuit_ids = $db->get_circuits_by_interface_id( interface_id => $orig_interface_id);

    my $dberror;
    if ( !defined $circuit_ids ) {
         $dberror = $db->get_error();
	     _log("Error: $dberror");
        return 0;
    }

    my @array;
    for my $cc (@$circuit_ids){ push (@array , $cc->{'circuit_id'});  }

    my $res = $db->move_edge_interface_circuits(
        orig_interface_id => $orig_interface_id,
        new_interface_id  => $new_interface_id,
        circuit_ids       => (@array > 0) ? \@array : undef
    );
    if ( !defined $res ) {
        $dberror = $db->get_error();
	    _log("Error: $dberror");
    	return 0;
    }
    _log("did we get here?");
    # now diff node
    if(!_update_cache_and_sync_node($res->{'dpid'})){
        _log("Issue diffing node");
        return 0;
    }
    my $dpid_hex = sprintf("%x",$res->{'dpid'});
    _log("Switch $dpid_hex updated");
    return $res;
}

sub _update_cache_and_sync_node {
    my $dpid = shift;

    _log("Called _update_cache_and_sync_node");

    # connect to dbus
    my $client;
    my $service;

    use constant FWDCTL_WAITING => 2;
    my $bus = Net::DBus->system;
    eval {
        $service = $bus->get_service("org.nddi.fwdctl");
        $client  = $service->get_object("/controller1");
    };
    if ($@) {
        warn "Error in _connect_to_fwdctl: $@";
        return 0;
    }
    if ( !defined $client ) {
        warn "Issue communicating with fwdctl";
        return 0;
    }
    _log("got here?");
    # first update fwdctl's cache
    my ($res,$event_id) = $client->update_cache(-1);
    _log("got here? 2");
    my $final_res = FWDCTL_WAITING;
    while($final_res == FWDCTL_WAITING){
        sleep(1);
        _log("final_res is FWDCTL_WAITING ");
        $final_res = $client->get_event_status($event_id);
    }
    # now sync the node
    ($res,$event_id) = $client->force_sync($dpid);
    $final_res = FWDCTL_WAITING;
    while($final_res == FWDCTL_WAITING){
        sleep(1);
        _log("final_res is FWDCTL_WAITING ");
        $final_res = $client->get_event_status($event_id);
    }
    _log("got here? 3");
    return 1;
}

1;