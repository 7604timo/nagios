#!/usr/bin/perl
#
#
# There's probably much neater solutions to this, but this script serves me very well in integrating Canon priner stats into Nagios and keeping users happy
# It uses SNMP to get everything it can about a Canon IrADV printer and over the network and print it all out, with the '-N' option to make the output Nagios-friendly
# You can optionally have a DB connection to store printer page counts, but it's not necessary as all printer data is collected through SNMP - you just need the IP address
# Obviously SNMP has to be enabled on the printer!
#
#
#use strict;
#use warnings;
use Switch;
use DBI;
use Net::SNMP;
use Data::Dumper;
use Term::ANSIColor qw(:constants);
use Getopt::Std;

# Counters required for managed print providers to get page counts
@interesting_counters = (106,109,113,123);

my %options=();
getopts("t:H:Nz", \%options);
# Help message etc
(my $script_name = $0) =~ s/.\///;

my $help_info = <<END;
\n$script_name - v1.0

Nagios script to check stats of a Canon IrADV device

Usage:
-t      Type of check: [ cyan|magenta|yellow|black | paper | toner | consumables | features | errors | counters | all ]
-H	[optional] IP address of device to check. Default is to check all printers in DB
-N	[optional] Nagios output mode

Example:
$script_name -t consumables
$script_name -H 192.168.1.1 -t consumables

END


# If we don't have the needed command line arguments exit with UNKNOWN.
if(!defined $options{t}){
        print "$help_info Not all required options were specified.\n\n";
        exit $UNKNOWN;
}


# Nagios return codes
$OK = 0;
$WARNING = 1;
$CRITICAL = 2;
$UNKNOWN = 3;
$STATUS = 0;

# Connect to a DB to get list of printers and IP addresses,
#  and to store page counts for historical data.
#  Structure is simply these columns:
#  id(int), model(varchar), ip(varchar), mac(varchar), location(varchar), serial(varchar), enabled(int)
my $sth;
$dbh = DBI->connect('DBI:mysql:canon_printers', 'dbUser', 'myPassword'
                                   ) || die "Could not connect to database: $DBI::errstr";

# Prepare to insert page count data:
$str = $dbh->prepare("insert into page_counts (mono, colour, host_id) values (?,?,?)");


# Figuring out these took a while!
# This is all the Canon SNMP OID tables that tell us about the machines
my $toner_colour_table = ".1.3.6.1.2.1.43.12.1.1.4.1";
my $toner_type_table = ".1.3.6.1.2.1.43.11.1.1.6.1";
my $toner_max_table = ".1.3.6.1.2.1.43.11.1.1.8.1";
my $toner_current_table = ".1.3.6.1.2.1.43.11.1.1.9.1";
my $waste_type = ".1.3.6.1.2.1.43.11.1.1.6.1.5";
my $waste_empty = ".1.3.6.1.2.1.43.11.1.1.8.1.5";
my $waste_current = ".1.3.6.1.2.1.43.11.1.1.9.1.5";
my $finisher_type_table = ".1.3.6.1.2.1.43.31.1.1.5.1";
my $finisher_max_table = ".1.3.6.1.2.1.43.31.1.1.7.1";
my $finisher_current_table = ".1.3.6.1.2.1.43.31.1.1.8.1";
my $sysname = ".1.3.6.1.2.1.43.5.1.1.16.1";
my $location = ".1.3.6.1.2.1.1.6.0";
my $serial = ".1.3.6.1.2.1.43.5.1.1.17.1";
my $uptime = ".1.3.6.1.2.1.1.3.0";
my $firmware = ".1.3.6.1.2.1.25.3.2.1.3.1";
my $features_table = ".1.3.6.1.4.1.1602.1.5.5.1.2.1.3.1";
my $error_table = ".1.3.6.1.2.1.43.18.1.1.8.1";
my $counters_table = ".1.3.6.1.4.1.1602.1.11.1.3.1.4";
my $tray_type_table = ".1.3.6.1.2.1.43.9.2.1.7.1";
my $tray_max_table = ".1.3.6.1.2.1.43.9.2.1.5.1";
my $tray_current_table = ".1.3.6.1.2.1.43.9.2.1.6.1";
my $drawer_type_table = ".1.3.6.1.2.1.43.8.2.1.13.1";
my $drawer_max_table = ".1.3.6.1.2.1.43.8.2.1.9.1";
my $drawer_current_table = ".1.3.6.1.2.1.43.8.2.1.10.1";

# Were we passed an IP, or are we taking the list of IPs from a db?
my @targets;
if($options{H}) {
        push(@targets, $options{H});	# IP address on the command line..
	} else {
		# Get list of printers
		$sth = $dbh->prepare("select ip from printers where enabled=1");
		$sth->execute();
		while(my @row = $sth->fetchrow_array) {
		 push(@targets, $row[0]);
		}
	}

foreach $i (@targets) {
	$hostisup = 1;
	$ip = $i;
  	($session, $error) = Net::SNMP->session(
      		-hostname  => $ip,
      		-community => 'public',
		-timeout => '5'
   	);
   if (!defined $session) {
      printf "SNMP Error: %s.\n", $error;
      exit 1;
   }

	$sysinfo = $session->get_request(-varbindlist => [$location, $serial, $uptime, $sysname, $firmware]);
	switch($options{t}) {
		case("firmware") {
			&firmware();
		}
		case("paper") {
			&paper();
		}
		case("toners") {
			&toners();
		}
		case("consumables") {
			&consumables();
		}
		case("all") {
			&consumables("all");
		}
		case("features") {
			&features();
		}
		case("saddle") {
			($STATUS,$msg) = &finisher("saddle");
		}
		case("staples") {
			($STATUS,$msg) = &finisher("staples");
		}
		case("errors") {
			($STATUS,$msg) = &errors();
		}
		case("counters") {
			&counters();
		}
		case(["cyan","magenta","yellow","black"]) {
			my $retval = &toners($options{t});
			if($retval) {exit $retval;}
		}
		case("waste") {
			($STATUS,$msg) = &check_waste_error();
		}
	}

	if($rfinisher_type_table) {
		&finisher();
	}


	if($rerror_table) {
	}
	print($msg);
	# Are we running in Nagios mode?
	if($options{N}) {
		exit($STATUS);	# Yes, exit with the status vairable set as exit code..
	}
}
#$session->close();

# Query the device using the SNMP session to get consumable levels, warn if below 20%
#  and print out counter information
sub consumables() {
	my ($arg) = @_;
	my $rtoner_colour_table = $session->get_table(-baseoid => $toner_colour_table);
	my $rtoner_max_table = $session->get_table(-baseoid => $toner_max_table);
	my $rtoner_current_table = $session->get_table(-baseoid => $toner_current_table);
	my $rtoner_type_table = $session->get_table(-baseoid => $toner_type_table);
	my $rcounters_table = $session->get_table(-baseoid => $counters_table);
	my $waste = $session->get_request(-varbindlist => [$waste_type, $waste_empty, $waste_current]);
	my $rfinisher_type_table = $session->get_table(-baseoid => $finisher_type_table);
	my $rfinisher_max_table = $session->get_table(-baseoid => $finisher_max_table);
	my $rfinisher_current_table = $session->get_table(-baseoid => $finisher_current_table);
	my $toner_string;
  	# Query the finisher unit to see how many staples are left:
	foreach my $key (keys %$rfinisher_type_table) {
               	my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		my $type = $rfinisher_type_table->{$finisher_type_table.".".$counter_id};
		my $max = $rfinisher_max_table->{$finisher_max_table.".".$counter_id};
		my $current = $rfinisher_current_table->{$finisher_current_table.".".$counter_id};
		my $percent = ($current/$max)*100;
		if(($percent <= 20) || ($arg eq "all")) {
			$toner_string .= "   $type: $percent%\n";
		}
	}
  	# Query the printer to see how much toner is left.
	foreach my $key (keys %$rtoner_colour_table) {
                my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		my $colour = $rtoner_colour_table->{$toner_colour_table.".".$counter_id};
		my $type = $rtoner_type_table->{$toner_type_table.".".$counter_id};
		my $max = $rtoner_max_table->{$toner_max_table.".".$counter_id};
		my $current = $rtoner_current_table->{$toner_current_table.".".$counter_id};
		my $percent = ($current/$max)*100;
		if(($percent <= 20) || ($arg eq "all")) {
#			$toner_string .= "$colour ($type): $percent% in ".$sysinfo->{$serial}."(".$sysinfo->{$location}.")\n";
			$toner_string .= "   $type: $percent%\n";
		}
	}

  	# Check the waste toner, but also check the printer error message to see if there's a warning about
  	#  about it because the SNMP data only tells you when the waste is full, not when it's almost full
	my ($wstatus, $wmsg) = check_waste_error();
	if(($wstatus ne $OK) || ($arg eq "all")) {
		$toner_string .= "   ".$wmsg;
	}

  	# If any consumables need replacing, print it out:
	if($toner_string) {
#		print("* Printer in ".$sysinfo->{$location}." ".$sysinfo->{$serial}." (".$sysinfo->{$sysname}.")\n");
		print("Consumables for ".$ip." ");
		print(GREEN,$sysinfo->{$serial},RESET);
		print(" in ".$sysinfo->{$location}.":\n");
		print("$toner_string");
		foreach my $key (keys %$rcounters_table) {
			my ($counter_id) = $key =~ m/\.([0-9]+)$/;
			if($counter_id ~~ @interesting_counters) {
				print("   PageCount ($counter_id): ".$rcounters_table->{$key}."\n");
			}
		}
	}

}

# Get device firmware version
sub firmware() {
	print($sysinfo->{$firmware}."\n");
}

# Get paper levels
sub paper() {
	my $rtray_type_table = $session->get_table(-baseoid => $tray_type_table);
	my $rtray_max_table = $session->get_table(-baseoid => $tray_max_table);
	my $rtray_current_table = $session->get_table(-baseoid => $tray_current_table);
	my $rdrawer_type_table = $session->get_table(-baseoid => $drawer_type_table);
	my $rdrawer_max_table = $session->get_table(-baseoid => $drawer_max_table);
	my $rdrawer_current_table = $session->get_table(-baseoid => $drawer_current_table);

	print("Paper Drawers\n");
	foreach my $key (sort(keys %$rdrawer_type_table)) {
                my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		my $type = $rdrawer_type_table->{$drawer_type_table.".".$counter_id};
		my $max = $rdrawer_max_table->{$drawer_max_table.".".$counter_id};
		my $current = $rdrawer_current_table->{$drawer_current_table.".".$counter_id};
		my $percent = ($current/$max)*100;
		print("* $type: $percent%\n");
	}

	print("Paper Trays\n");
	foreach my $key (sort(keys %$rtray_type_table)) {
                my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		my $type = $rtray_type_table->{$tray_type_table.".".$counter_id};
		my $max = $rtray_max_table->{$tray_max_table.".".$counter_id};
		my $current = $rtray_current_table->{$tray_current_table.".".$counter_id};
		my $percent = ($current/$max)*100;
		print("* $type: $percent%\n");
	}
}
# Get page counts
sub counters() {
	my $rcounters_table = $session->get_table(-baseoid => $counters_table);
	print("Counters for "."(".$sysinfo->{$location}.") ");
	print(GREEN,$sysinfo->{$serial},RESET);
	print(" [".$ip."]:\n");
	foreach my $key (keys %$rcounters_table) {
		my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		if($counter_id ~~ @interesting_counters) {
			print("* $counter_id: ".$rcounters_table->{$key}."\n");
		}
	}
}

# Get any errors
sub errors() {
	my $rerror_table = $session->get_table(-baseoid => $error_table);
	my $serror;
	foreach my $key (keys %$rerror_table) {
#		my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		if($options{N}) {
			if($rerror_table->{$key} =~ m/(toner|paper)/i) {
				$str = "WARNING: ";
				$STATUS = $WARNING;
			} else {
				$str = "CRITICAL: ";
				$STATUS = $CRITICAL;
			}
			$serror .= " ** ".$str.$rerror_table->{$key}." ** ";
		} else {
			$serror .= "* ".$rerror_table->{$key}."\n";
		}
	}
	if(!$serror) { $STATUS = $OK; $serror = "OK: No Errors\n"; }
	return ($STATUS,$serror);
}

# Get device information, like serial number, model, attached finisher
sub features() {
	my $rfeatures_table = $session->get_table(-baseoid => $features_table);
	print(GREEN,$sysinfo->{$sysname},RESET);
	print(" [".$ip."] ".$sysinfo->{$location}." (".$sysinfo->{$serial}.")\n");
	foreach my $key (keys %$rfeatures_table) {
		print("* ".$rfeatures_table->{$key}."\n");
	}
}

# Get toner levels
sub toners() {
	my ($pcolour) = @_;
#	print("Toners:\n");
	my @colours = ("black", "yellow", "magenta", "cyan");
	if(!$options{N}) {
		print("Consumables for ");
		print(GREEN,$sysinfo->{$serial},RESET);
		print(" in ".$sysinfo->{$location}.":\n");
		print("$toner_string");
	}
	if(defined $pcolour) {
		&a_toner($pcolour);
	} else {
		foreach my $colour (@colours) {
			&a_toner($colour);
		}
	}

}

# Helper function to get one toner details, like type of Canon toner container and current levels
# Some printers report toner is out on error screen, but SNMP stats show 5% remaining.
# We can also scan the error screen and use that to decide if toner is out
sub a_toner() {
	my ($pcolour) = @_;
	my $rtoner_colour_table = $session->get_table(-baseoid => $toner_colour_table);
	my $rtoner_max_table = $session->get_table(-baseoid => $toner_max_table);
	my $rtoner_current_table = $session->get_table(-baseoid => $toner_current_table);
	my $rtoner_type_table = $session->get_table(-baseoid => $toner_type_table);
	foreach my $key (keys %$rtoner_colour_table) {
                my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		my $colour = $rtoner_colour_table->{$toner_colour_table.".".$counter_id};
		my $type = $rtoner_type_table->{$toner_type_table.".".$counter_id};
		my $max = $rtoner_max_table->{$toner_max_table.".".$counter_id};
		my $current = $rtoner_current_table->{$toner_current_table.".".$counter_id};
		my $percent = ($current/$max)*100;
		if($colour eq $pcolour) {
			if($options{N}) {
				switch($percent) {
					case {$percent == 0} {
						print("CRITICAL: ".ucfirst("$colour available $percent%\n"));
						return $CRITICAL;
					}
					case {$percent <= 5} {
						# Dodgy printers sometimes report 5% ink left, but show error anyway..
						# 'The Black toner is out.'
						# 'toner is out (black).'
						my $rerror_table = $session->get_table(-baseoid => $error_table);
#						print Dumper $rerror_table;
						foreach my $key (keys %$rerror_table) {
							if($rerror_table->{$key} =~ m/The $colour toner is out./i) {
								print("CRITICAL: ".ucfirst("$colour available $percent%, but error flagged\n"));
								return $CRITICAL;
							} elsif($rerror_table->{$key} =~ m/toner is out \($colour\)./i) {
								print("CRITICAL: ".ucfirst("$colour available $percent%, but error flagged\n"));
								return $CRITICAL;
							} elsif($rerror_table->{$key} =~ m/$colour/i) {
								$e = "*".$rerror_table->{$key}."*";
								print("WARNING: ".ucfirst("$colour available $percent% [$e]\n"));
								return $WARNING;
							}
							
						}
					}
					case {$percent <= 20} {
						print("WARNING: ".ucfirst("$colour available $percent%\n"));
						return $WARNING;
					}
					print("OK: ".ucfirst("$colour available $percent%\n"));
					return $OK;
				}
			} else {
				print("* $colour ($type): $percent%\n");
			}
		}
	}
}

# Check the finisher to see how many staples it has left
sub finisher() {
	my ($method) = @_;
	my $rfinisher_type_table = $session->get_table(-baseoid => $finisher_type_table);
	my $rfinisher_max_table = $session->get_table(-baseoid => $finisher_max_table);
	my $rfinisher_current_table = $session->get_table(-baseoid => $finisher_current_table);
#	print("Consumables for ");
#	print(GREEN,$sysinfo->{$serial},RESET);
#	print(" in ".$sysinfo->{$location}.":\n");
#	print("Finisher:\n");
	foreach my $key (keys %$rfinisher_type_table) {
               	my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		my $type = $rfinisher_type_table->{$finisher_type_table.".".$counter_id};
		my $max = $rfinisher_max_table->{$finisher_max_table.".".$counter_id};
		my $current = $rfinisher_current_table->{$finisher_current_table.".".$counter_id};
		my $percent = ($current/$max)*100;
		$search_type = lc($type);
#		print("Method: $method, Needle: $search_type\n");
		if($method eq "saddle") { $method = "saddle staples"; }
		if($method eq $search_type) {
			if($options{N}) {
				$msg = "OK: ";
				$STATUS = $OK;
				if($percent <= 20) { $STATUS = $WARNING; $msg = "WARNING: ";}
				if($percent == 0) { $STATUS = $CRITICAL; $msg = "CRITICAL: ";}
				$msg .= "$type: $percent%\n";
			} else {
#				$msg = "* $type: $percent%\n";
				$msg = "Type: $type, MAX: $max, CURRENT: $current\n";
			}
#			print("Type: $type, MAX: $max, CURRENT: $current\n");
		}
	}
	return($STATUS,$msg);
}

# Check the waste toner using SNMP and the error display to get a warning before the bottle is actually full
sub waste() {
	my $waste = $session->get_request(-varbindlist => [$waste_type, $waste_empty, $waste_current]);
	my $msg, $STATUS;
	if($options{N}) {
		if($waste->{$waste_current} == $waste->{$waste_empty}) {
			$msg = "OK: Waste Toner Not Full\n";
			$STATUS = $OK;
		} else {
			$msg = "CRITICAL: Waste Toner FULL? [".$waste->{$waste_current}." / ".$waste->{$waste_empty}."]\n";
			$STATUS = $CRITICAL;
		}
	} else {
		$msg = "* ".$waste->{$waste_type}.": ".$waste->{$waste_current}." / ".$waste->{$waste_empty}."\n";
	}
	return ($STATUS,$msg);

}

# Waste toner 'nearly full' only gets reported as an 'error'.
sub check_waste_error() {
	my $rerror_table = $session->get_table(-baseoid => $error_table);
	my $serror, $wmsg, $status = $OK, $pmsg = "OK: ", $status2, $msg2;
	foreach my $key (keys %$rerror_table) {
#		my ($counter_id) = $key =~ m/\.([0-9]+)$/;
		if($rerror_table->{$key} =~ m/waste/) {
			$serror .= "   ".$rerror_table->{$key}."\n";
			if($serror =~ m/The waste toner container is full soon./) {
				$pmsg = "WARNING: ";
				$wmsg = "Waste Toner: 90%\n";
				$status = $WARNING;
			}
			if($serror =~ m/waste toner needs to be checked./) {
				$pmsg = "CRITICAL: ";
				$wmsg = "Waste Toner: 100%\n";
				$status = $CRITICAL;
			}
			if($serror =~ m/waste toner container is full/) {
				$pmsg = "CRITICAL: ";
				$wmsg = "Waste Toner: 100%\n";
				$status = $CRITICAL;
			}
			if($serror =~ m/waste toner is full./) {
				$pmsg = "CRITICAL: ";
				$wmsg = "Waste Toner: 100%\n";
				$status = $CRITICAL;
			}
		}
	}
	if(!defined($wmsg)) { $wmsg = "Waste Toner OK\n"; }
	if(defined($options{N})) { 
		$wmsg = $pmsg.$wmsg;
	}
	return($status,$wmsg);
}
