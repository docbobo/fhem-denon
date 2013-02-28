# $Id$
##############################################################################
#
#	  71_DENON_AVR.pm
#	  An FHEM Perl module for controlling Denon AV-Receivers
#	  via network connection. 
#
#	  Copyright by Boris Pruessmann
#	  e-mail: boris@pruessmann.org
#
#     Greatly inspired by 71_YAMAHA_PVR.pm originally written by Markus Bloch
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
#	  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	See the
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
	$hash->{ShutdownFn} = "DENON_AVR_Shutdown";

	$hash->{AttrList}  = "do_not_notify:0,1 loglevel:0,1,2,3,4,5 do_not_send_commands:0,1 ".$readingFnAttributes;
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
	$hash->{helper}{INTERVAL} = 60 * 5;

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
		syswrite($hash->{TCPDev}, $msg."\r") if ($hash->{TCPDev});
	
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
			$power = "Off";
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

		readingsBulkUpdate($hash, "volume_level", lc($volume / 10));
	}
	elsif ($msg =~/SI(.+)/)
	{
		my $input = $1;
		readingsBulkUpdate($hash, "input", $input);
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
	my ($hash, $def) = @_;
	
	Log 5, "DENON_AVR_Define($def) called.";

	my @a = split("[ \t][ \t]*", $def);
	if (@a != 3)
	{
		my $msg = "wrong syntax: define <name> DENON_AVR <ip-or-hostname>";
		Log 2, $msg;

		return $msg;
	}

	DevIo_CloseDev($hash);

	my $name = $a[0];
	my $host = $a[2];

	$hash->{DeviceName} = $host.":23";
	my $ret = DevIo_OpenDev($hash, 0, "DENON_AVR_DoInit");
	
	InternalTimer(gettimeofday() + 5,"DENON_AVR_UpdateConfig", $hash, 0);
	
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

#####################################
sub
DENON_AVR_Get($@)
{
	my ($hash, @a) = @_;
	my $what;

	return "argument is missing" if (int(@a) != 2);
	$what = $a[1];

	if ($what =~ /^(power|volume_level|mute)$/)
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
		return "Unknown argument $what, choose one of param power input volume_level mute get";
	}
}

###################################
sub
DENON_AVR_Set($@)
{
	my ($hash, @a) = @_;

	my $what = $a[1];
	my $usage = "Unknown argument $what, choose one of on off toggle volume:slider,0,1,98 mute:on,off rawCommand statusRequest";

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
		return $usage if (!defined($mute));
		
		return DENON_AVR_Command_SetMute($hash, $mute);
	}
	elsif ($what eq "volume")
	{
		my $volume = $a[2];
		return $usage if (!defined($volume));
		
		return DENON_AVR_Command_SetVolume($hash, $volume);
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
		$attr{$name}{webCmd} = "toggle:on:off:statusRequest";
	}
	
	RemoveInternalTimer($hash);
	InternalTimer(gettimeofday() + $hash->{helper}{INTERVAL}, "DENON_AVR_KeepAlive", $hash, 0);
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

	RemoveInternalTimer($hash);
	InternalTimer(gettimeofday() + $hash->{helper}{INTERVAL}, "DENON_AVR_KeepAlive", $hash, 0);
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
	
	return undef;
}

1;

=pod
=begin html

<a name="DENON_AVR"></a>
<h3>DENON_AVR</h3>
<ul>

  <a name="DENON_AVRdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; DENON_AVR &lt;ip-address&gt;</code>
    <br><br>

    This module controls AV receiver from Denon via network connection. You are able
    to power your AV reveiver on and off, query it's power state, select the volume
    or mute/unmute the volume.<br><br>

    Example:
    <PRE>
       define AV_Receiver DENON_AVR 192.168.0.10
       
    </PRE>
  </ul>
  
  <a name="DENON_AVRset"></a>
  <b>Set </b>
  <ul>
    <code>set &lt;name&gt; &lt;command&gt; [&lt;parameter&gt;]</code>
    <br><br>
    Currently, the following commands are defined: 

<pre>on
off
volume 0..98
mute on
mute off
rawCommand</pre>
</ul>
  <a name="DENON_AVRget"></a>
  <b>Get</b>
  <ul>
    <code>get &lt;name&gt; &lt;what&gt;</code>
    <br><br>
    Currently, the following commands are defined and return the current state of the receiver.
<pre>power
mute 
volume_level</pre>
  </ul>
  <a name="DENON_AVRattr"></a>
  <b>Attributes</b>
  <ul>
  
    <li><a href="#loglevel">loglevel</a></li>
    <li><a href="#do_not_notify">do_not_notify</a></li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li><br>
  </ul>
<br>
  <b>Implementator's note</b>
  <ul>
    The module is only usable if you activate "Network Standby" on your receiver.<br><br>
    Technically there are many more commands and readings possible, but I think
    these are the main usecases within FHEM.
  </ul>
  <br>
</ul>


=end html
=begin html_DE

<a name="DENON_AVR"></a>
<h3>DENON_AVR</h3>
<ul>

  <a name="DENON_AVRdefine"></a>
  <b>Definition</b>
  <ul>
    <code>define &lt;name&gt; DENON_AVR &lt;IP-Addresse&gt;</code>
    <br><br>

    Dieses Modul steuert AV-Receiver des Herstellers Denon &uuml;ber die Netzwerkschnittstelle.
    Es bietet die M&ouml;glichkeit den Receiver an-/auszuschalten, die Lautst&auml;rke zu &auml;ndern, 
	den Receiver "Stumm" zu schalten, sowie den aktuellen Status abzufragen.
    <br><br>

    Beispiel:
    <PRE>
       define AV_Receiver DENON_AVR 192.168.0.10
    </PRE>
  </ul>

  <a name="DENON_AVRset"></a>
  <b>Set-Kommandos </b>
  <ul>
    <code>set &lt;Name&gt; &lt;Kommando&gt; [&lt;Parameter&gt;]</code>
    <br><br>
    Aktuell werden folgende Kommandos unterst&uuml;tzt:

<pre>on
off
volume 0..98
mute on
mute off
rawCommand</pre>

</ul>

  <a name="DENON_AVRget"></a>
  <b>Get-Kommandos</b>
  <ul>
    <code>get &lt;Name&gt; &lt;Parameter&gt;</code>
    <br><br>
    Aktuell stehen folgende Parameter zur Verf&uuml;gung welche den aktuellen Status des Receivers zur&uuml;ck geben.<br><br>
     <ul>
     <li><code>power</code> - Betriebszustand des Receiveres/Zone (on oder off)</li>
     <li><code>mute</code> - Lautlos an oder aus (on oder off)</li>
     <li><code>volume_level</code> - Lautst&auml;rkepegel in dB</li>
     </ul>
  </ul>
  <br>
  <a name="DENON_AVRattr"></a>
  <b>Attribute</b>
  <ul>
  
    <li><a href="#loglevel">loglevel</a></li>
    <li><a href="#do_not_notify">do_not_notify</a></li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li><br>
  </ul>
<br>
  <b>Hinweise des Autors</b>
  <ul>
    Dieses Modul ist nur nutzbar, wenn die Option "Network Standby" am Receiver aktiviert ist.<br><br>
    Technisch gesehen sind viel mehr Kommandos und R&uuml;ckgabewerte m&ouml;glich, aber dies sind meiner
    Meinung nach die wichtigsten innerhalb von FHEM.
  </ul>
  <br>
</ul>
=end html_DE

=cut
