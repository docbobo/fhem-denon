# $Id$ 71_DENON_AVR.pm 2015-02-14 17:00:00 xusader $
##############################################################################
#
#	  71_DENON_AVR.pm
#	  An FHEM Perl module for controlling Denon AV-Receivers
#	  via network connection. 
#
#     Currently supported are:  power (on|off)
#                               volumeStraight (-80 ... 18)
#                               volume (0 ... 98)
#                               mute (on|off)
#				input (select input source)
#				sound (select sound mode)
#
#     In addition, you can send any documented command from the "DENON AVR
#     protocol documentation" via "rawCommand <command>"; e.g. "rawCommand
#     PWON" does the exact same thing as "power on"
#
#	  Copyright by Boris Pruessmann
#	           
#         forked by xusader/michaelmueller
#			forked by quigley
#			now needs to specify telnetport 23 in define for TCP/IP:
#			define myDenon DENON_AVR 192.168.0.12:23
#			or define for serial port:
#			define myDenon DENON_AVR /dev/ttyUSB0@9600
#          
#	  This file is part of fhem.
#
#	  Fhem is free software: you can redistribute it and/or modify
#	  it under the terms of the GNU General Public License as published by
#	  the Free Software Foundation, either version 2 of the License, or
#	  (at your option) any later version.
#
#	  Fhem is distributed in the hope that it will be useful,
#	  but WITHOUT ANY WARRANTY; without even the implied warranty of
#	  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#	  GNU General Public License for more details.
#
#	  You should have received a copy of the GNU General Public License
#	  along with fhem.	If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
package main;

use strict;
use warnings;

use Time::HiRes qw(usleep gettimeofday);

###################################
my %commands = 
(
	"power:on" => "PWON",
	"power:off" => "PWSTANDBY",
	"mute:on" => "MUON",
	"mute:off" => "MUOFF"
);

my %powerStateTransition =
(
	"on"  => "off",
	"off" => "on"
);

my %inputs = 
(
	    "TUNER" => "",
	    "DVD" => "",
	    "BD" => "",
	    "TV" => "",
	    "SAT/CBL" => "",
	    "MPLAY" => "",
	    "GAME" => "",
	    "AUX1" => "",
	    "NET" => "",
	    "SPOTIFY" => "",
	    "FLICKR" => "",
	    "FAVORITES" => "",
	    "IRADIO" => "",
	    "SERVER" => "",
	    "USB/IPOD" => "",
	    "USB" => "",
	    "IPD" => "",
	    "IRP" => "",
	    "FVP" => ""
);

my %sounds = 
(
	    "MOVIE" => "",
	    "MUSIC" => "",
	    "GAME" => "",
	    "DIRECT" => "",
	    "STEREO" => "",
	    "STANDARD" => "",
	    "DOLBY_DIGITAL" => "",
	    "DTS_SURROUND" => "",
	    "MCH_STEREO" => "",
	    "ROCK_ARENA" => "",
	    "JAZZ_CLUB" => "",
	    "MONO_MOVIE" => "",
	    "MATRIX" => "",
	    "VIDEO_GAME" => "",
	    "VIRTUAL" => ""
);

###################################
sub
DENON_AVR_Initialize($)
{
	my ($hash) = @_;

	Log 5, "DENON_AVR_Initialize: Entering";
		
	require "$attr{global}{modpath}/FHEM/DevIo.pm";
	
# Provider
	$hash->{ReadFn}	 = "DENON_AVR_Read";
	$hash->{WriteFn} = "DENON_AVR_Write";
 
# Device	
	$hash->{DefFn}		= "DENON_AVR_Define";
	$hash->{UndefFn}	= "DENON_AVR_Undefine";
	$hash->{GetFn}		= "DENON_AVR_Get";
	$hash->{SetFn}		= "DENON_AVR_Set";
	$hash->{AttrFn}     	= "DENON_AVR_Attr";
	$hash->{ShutdownFn} 	= "DENON_AVR_Shutdown";

	$hash->{AttrList}  = "do_not_notify:0,1 loglevel:0,1,2,3,4,5 do_not_send_commands:0,1 keepalive ".$readingFnAttributes;
}

#####################################
sub
DENON_AVR_DoInit($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
  
	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_DoInit: Called for $name";

	DENON_AVR_Command_StatusRequest($hash);

	$hash->{STATE} = "Initialized";

	return undef;
}

###################################
sub
DENON_AVR_Read($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_Read: Called for $name";

	my $buf = DevIo_SimpleRead($hash);
	return "" if (!defined($buf));

	my $culdata = $hash->{PARTIAL};
	Log $ll5, "DENON_AVR_Read: $culdata/$buf"; 
	$culdata .= $buf;

	readingsBeginUpdate($hash);
	while ($culdata =~ m/\r/) 
	{
		my $rmsg;
		($rmsg, $culdata) = split("\r", $culdata, 2);
		$rmsg =~ s/\r//;

		DENON_AVR_Parse($hash, $rmsg) if($rmsg);
	}	
	readingsEndUpdate($hash, 1);

	$hash->{PARTIAL} = $culdata;
}

#####################################
sub
DENON_AVR_Write($$$)
{
	my ($hash, $fn, $msg) = @_;

	Log 5, "DENON_AVR_Write: Called";
}

###################################
sub
DENON_AVR_SimpleWrite(@)
{
	my ($hash, $msg) = @_;
	my $name = $hash->{NAME};
	
	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_SimpleWrite: $msg";
	
	my $doNotSendCommands = AttrVal($name, "do_not_send_commands", "0");
	if ($doNotSendCommands ne "1")
	{	
		#syswrite($hash->{TCPDev}, $msg."\r") if ($hash->{TCPDev});
		#$hash->{USBDev}->write($msg."\r")    if($hash->{USBDev});
	   DevIo_SimpleWrite($msg."\r");

		# Let's wait 100ms - not sure if still needed
		usleep(100 * 1000);
	
		# Some linux installations are broken with 0.001, T01 returns no answer
		select(undef, undef, undef, 0.01);
	}
}

###################################
sub
DENON_AVR_Parse(@)
{
	my ($hash, $msg) = @_;
	my $name = $hash->{NAME};

	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_Parse: Parsing <$msg>";

	if ($msg =~ /PW(.+)/)
	{
		my $power = lc($1);
		if ($power eq "standby")
		{
			$power = "off";
		}

		readingsBulkUpdate($hash, "power", $power);
		$hash->{STATE} = $power;
	}
	elsif ($msg =~ /MU(.+)/)
	{
		readingsBulkUpdate($hash, "mute", lc($1));
	}
	elsif ($msg =~ /MVMAX (.+)/)
	{
		Log $ll5, "DENON_AVR_Parse: Ignoring maximum volume of <$1>";	
	}
	elsif ($msg =~ /MV(.+)/)
	{
		my $volume = $1;
		if (length($volume) == 2)
		{
			$volume = $volume."0";
		}
		readingsBulkUpdate($hash, "volumeStraight", $volume / 10 - 80);
		readingsBulkUpdate($hash, "volume", $volume / 10);
	}
	elsif ($msg =~/SI(.+)/)
	{
		readingsBulkUpdate($hash, "input", $1);
	}
	elsif ($msg =~/MS(.+)/)
	{
		readingsBulkUpdate($hash, "sound", $1);
	}
	else 
	{
		Log $ll5, "DENON_AVR_Parse: Unknown message <$msg>";	
	}
}

###################################
sub
DENON_AVR_Define($$)
{
	my ($hash, $def, $name) = @_;
	
	Log 5, "DENON_AVR_Define($def) called.";

	my @a = split("[ \t][ \t]*", $def);
	
	$attr{$name}{"stateFormat"} = "power";
	
	if (@a != 3)
	{
		my $msg = "wrong syntax: define <name> DENON_AVR <ip-or-hostname>";
		Log 2, $msg;

		return $msg;
	}

	DevIo_CloseDev($hash);

	my $name = $a[0];
	my $host = $a[2];
	#$hash->{DeviceName} = $host.":23";
	$hash->{DeviceName} = $host;
	my $ret = DevIo_OpenDev($hash, 0, "DENON_AVR_DoInit");
	
	InternalTimer(gettimeofday() + 5, "DENON_AVR_UpdateConfig", $hash, 0);
	
	return $ret;
}

#############################
sub
DENON_AVR_Undefine($$)
{
	my($hash, $name) = @_;
	
	Log 5, "DENON_AVR_Undefine: Called for $name";	

	RemoveInternalTimer($hash);
	DevIo_CloseDev($hash); 
	
	return undef;
}

#############################
sub
DENON_AVR_Get($@)
{
	my ($hash, @a) = @_;
	my $what;

	return "argument is missing" if (int(@a) != 2);
	$what = $a[1];

	if ($what =~ /^(power|volumeStraight|volume|volumeDown|volumeUp|mute|input|sound)$/)
	{
		if(defined($hash->{READINGS}{$what}))
		{
			
			return $hash->{READINGS}{$what}{VAL};
		}
		else
		{
			return "no such reading: $what";
		}
	}
	else
	{
		return "Unknown argument $what, choose one of power volumeStraight volume volumeDown volumeUp mute input sound";
	}
}

###################################
sub
DENON_AVR_Set($@)
{
	my ($hash, @a) = @_;

	my $what = $a[1];
	
	my $usage = "Unknown argument $what, choose one of on off toggle volumeDown volumeUp volumeStraight:slider,-80,1,18 volume:slider,0,1,98 mute:on,off " . 
		    "input:" . join(",", sort keys %inputs) . " " .
		    "sound:" . join(",", sort keys %sounds) . " " .
		    "rawCommand statusRequest"; 	

	if ($what =~ /^(on|off)$/)
	{
		return DENON_AVR_Command_SetPower($hash, $what);
	}
	elsif ($what eq "toggle")
	{
		my $newPowerState = $powerStateTransition{$hash->{STATE}};
		return $newPowerState if (!defined($newPowerState));		
		
		return DENON_AVR_Command_SetPower($hash, $newPowerState);
	}
	elsif ($what eq "mute")
	{
		my $mute = $a[2];
		return DENON_AVR_Command_SetMute($hash, $mute);
	}
	elsif ($what eq "input")
	{
		my $input = $a[2];
		return DENON_AVR_Command_SetInput($hash, $input);
	}
	elsif ($what eq "sound")
	{
		my $sound = $a[2];
		
		if (	 $sound eq "DOLBY_DIGITAL") {
		    $sound = "DOLBY DIGITAL";

		} elsif ($sound eq "DTS_SURROUND") {		
		    $sound = "DTS SURROUND";
		}
		elsif ($sound eq "MCH_STEREO") {		
		    $sound = "MCH STEREO";
		}
		elsif ($sound eq "ROCK_ARENA") {		
		    $sound = "ROCK ARENA";
		}
		elsif ($sound eq "JAZZ_CLUB") {		
		    $sound = "JAZZ CLUB";
		}
		elsif ($sound eq "MONO_MOVIE") {		
		    $sound = "MONO MOVIE";
		}
		elsif ($sound eq "VIDEO_GAME") {		
		    $sound = "VIDEO GAME";
		}
		
		return DENON_AVR_Command_SetSound($hash, $sound);
	}
	elsif ($what eq "volumeStraight")
	{
		my $volume = $a[2];
		return DENON_AVR_Command_SetVolume($hash, $volume + 80);
	}
	elsif ($what eq "volume")
	{
		my $volume = $a[2];
		return DENON_AVR_Command_SetVolume($hash, $volume);
	}
	elsif ($what eq "volumeDown")
	{
		my $cmd = "MVDOWN";
		DENON_AVR_SimpleWrite($hash, $cmd);
	}
	elsif ($what eq "volumeUp")
	{
		my $cmd = "MVUP";
		DENON_AVR_SimpleWrite($hash, $cmd);
	}
	elsif ($what eq "rawCommand")
	{
		my $cmd = $a[2];
		DENON_AVR_SimpleWrite($hash, $cmd); 
	}
	elsif ($what eq "statusRequest")
	{
	# Force update of status
	return DENON_AVR_Command_StatusRequest($hash);
	}
	else
	{
	return $usage;
	}
    return undef;
}

###################################
sub
DENON_AVR_Attr($@)
{
	my @a = @_;
	
	my $what = $a[2];
	if ($what eq "keepalive")
	{
		my $name = $a[1];
	    	my $hash = $defs{$name};
		
		my $keepalive = $a[3];
	
		my $ll5 = GetLogLevel($name, 5);
		Log $ll5, "DENON_AVR_Attr: Changing keepalive to <$keepalive> seconds";
	
		RemoveInternalTimer($hash);
		InternalTimer(gettimeofday() + $keepalive, "DENON_AVR_KeepAlive", $hash, 0);
	}
	
	return undef;
}

#####################################
sub
DENON_AVR_Shutdown($)
{
	my ($hash) = @_;

	Log 5, "DENON_AVR_Shutdown: Called";
}

#####################################
sub 
DENON_AVR_UpdateConfig($)
{
	# this routine is called 5 sec after the last define of a restart
	# this gives FHEM sufficient time to fill in attributes
	# it will also be called after each manual definition
	# Purpose is to parse attributes and read config
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my $webCmd	= AttrVal($name, "webCmd", "");
	if (!$webCmd)
	{
		$attr{$name}{webCmd} = "volumeStraight:mute:input:sound";
	}
	
	my $keepalive = AttrVal($name, "keepalive", 5 * 60);
	
	RemoveInternalTimer($hash);
	InternalTimer(gettimeofday() + $keepalive, "DENON_AVR_KeepAlive", $hash, 0);
}

#####################################
sub 
DENON_AVR_KeepAlive($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_KeepAlive: Called for $name";

	DENON_AVR_SimpleWrite($hash, "PW?"); 

	my $keepalive = AttrVal($name, "keepalive", 5 * 60);

	RemoveInternalTimer($hash);
	InternalTimer(gettimeofday() + $keepalive, "DENON_AVR_KeepAlive", $hash, 0);
}

#####################################
sub
DENON_AVR_Command_SetPower($$)
{
	my ($hash, $power) = @_;
	my $name = $hash->{NAME};
	
	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_Command_SetPower: Called for $name";

	my $command = $commands{"power:".lc($power)};
	DENON_AVR_SimpleWrite($hash, $command);
	
	readingsBeginUpdate($hash);	
	readingsBulkUpdate($hash, "power", $power);
	readingsEndUpdate($hash, 1);
	
	return undef;
}

#####################################
sub
DENON_AVR_Command_SetMute($$)
{
	my ($hash, $mute) = @_;
	my $name = $hash->{NAME};
	
	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_Command_SetMute: Called for $name";
	
	return "mute can only used when device is powered on" if ($hash->{STATE} eq "off");

	my $command = $commands{"mute:".lc($mute)};
	DENON_AVR_SimpleWrite($hash, $command);
	
	return undef;
}

#####################################
sub
DENON_AVR_Command_SetInput($$)
{
	my ($hash, $input) = @_;
	my $name = $hash->{NAME};
	
	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_Command_SetInput: Called for $name";

	DENON_AVR_SimpleWrite($hash, "SI".$input);
	readingsBeginUpdate($hash);	
	readingsBulkUpdate($hash, "input", $input);
	readingsEndUpdate($hash, 1);
	
	return undef;
}

#####################################
sub
DENON_AVR_Command_SetSound($$)
{
	my ($hash, $sound) = @_;
	my $name = $hash->{NAME};
	
	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_Command_SetSound: Called for $name";

	DENON_AVR_SimpleWrite($hash, "MS".$sound);
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "sound", $sound);	
	readingsEndUpdate($hash, 1);
	return undef;
}

#####################################
sub
DENON_AVR_Command_SetVolume($$)
{
	my ($hash, $volume) = @_;
	my $name = $hash->{NAME};
	
	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_Command_SetVolume: Called for $name";
	
	$volume = $volume * 10;
	if($hash->{STATE} eq "off")
	{
		return "volume can only used when device is powered on";
	}
	else
	{
		if ($volume % 10 == 0)
		{
			DENON_AVR_SimpleWrite($hash, "MV".($volume / 10));
		}
		else
		{
			DENON_AVR_SimpleWrite($hash, "MV".$volume);
		}
	}
	
	return undef;
}

#####################################
sub
DENON_AVR_Command_StatusRequest($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	my $ll5 = GetLogLevel($name, 5);
	Log $ll5, "DENON_AVR_Command_StatusRequest: Called for $name";

	DENON_AVR_SimpleWrite($hash, "PW?"); 
	DENON_AVR_SimpleWrite($hash, "MU?");
	DENON_AVR_SimpleWrite($hash, "MV?");
	DENON_AVR_SimpleWrite($hash, "SI?");
	DENON_AVR_SimpleWrite($hash, "MS?");
	DENON_AVR_SimpleWrite($hash, "ZM?");
	DENON_AVR_SimpleWrite($hash, "Z2?");
	DENON_AVR_SimpleWrite($hash, "Z3?");
	DENON_AVR_SimpleWrite($hash, "SLP?");
	
	return undef;
}

1;
