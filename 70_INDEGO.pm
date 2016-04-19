# $Id$
##############################################################################
#
#     70_INDEGO.pm
#     An FHEM Perl module for controlling a Bosch Indego.
#
#     Copyright by Ulf von Mersewsky
#     e-mail: umersewsky at gmail.com
#
#     This file is part of fhem.
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
#
# Version: 0.1.3
#
##############################################################################

package main;

use 5.012;
use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use HttpUtils;
use JSON qw(decode_json);

sub INDEGO_Set($@);
sub INDEGO_Get($@);
sub INDEGO_GetStatus($;$);
sub INDEGO_Define($$);
sub INDEGO_Undefine($$);

###################################
sub INDEGO_Initialize($) {
    my ($hash) = @_;

    Log3 $hash, 5, "INDEGO_Initialize: Entering";

    $hash->{GetFn}   = "INDEGO_Get";
    $hash->{SetFn}   = "INDEGO_Set";
    $hash->{DefFn}   = "INDEGO_Define";
    $hash->{UndefFn} = "INDEGO_Undefine";

    $hash->{AttrList} = "disable:0,1 " . $readingFnAttributes;

    return;
}

#####################################
sub INDEGO_GetStatus($;$) {
    my ( $hash, $update ) = @_;
    my $name     = $hash->{NAME};
    my $interval = $hash->{INTERVAL};

    Log3 $name, 5, "INDEGO $name: called function INDEGO_GetStatus()";

    RemoveInternalTimer($hash);
    InternalTimer( gettimeofday() + $interval, "INDEGO_GetStatus", $hash, 0 );

    return if ( AttrVal($name, "disable", 0) == 1 );

    # check device availability
    if (!$update) {
      INDEGO_SendCommand( $hash, "state" );
    }

    return;
}

###################################
sub INDEGO_Get($@) {
    my ( $hash, @a ) = @_;
    my $name = $hash->{NAME};
    my $what;

    Log3 $name, 5, "INDEGO $name: called function INDEGO_Get()";

    return "argument is missing" if ( int(@a) < 2 );

    $what = $a[1];

    if ( $what =~ /^(mapsvgcache)$/ ) {
        my $value = ReadingsVal($name, $what, "");
        if ($value eq "") {
          $value = ReadingsVal($name, ".$what", "");
          eval { require Compress::Zlib; };
          unless($@) {
            $value = Compress::Zlib::uncompress($value);
          }
        }
        if ( $value ne "" ) {
            return $value;
        } else {
            return "no such reading: $what";
        }
    } else {
        return "Unknown argument $what, choose one of mapsvgcache:noArg";
    }
}

###################################
sub INDEGO_Set($@) {
    my ( $hash, @a ) = @_;
    my $name  = $hash->{NAME};

    Log3 $name, 5, "INDEGO $name: called function INDEGO_Set()";

    return "No Argument given" if ( !defined( $a[1] ) );

    my $usage = "Unknown argument " . $a[1] . ", choose one of mow:noArg pause:noArg returnToDock:noArg reloadMap:noArg";

    my $cmd = '';
    my $result;


    # mow
    if ( $a[1] eq "mow" ) {
        Log3 $name, 2, "INDEGO set $name " . $a[1];

        INDEGO_SendCommand( $hash, "state", "mow" );
    }

    # pause
    elsif ( $a[1] eq "pause" ) {
        Log3 $name, 2, "INDEGO set $name " . $a[1];

        INDEGO_SendCommand( $hash, "state", "pause" );
    }

    # returnToDock
    elsif ( $a[1] eq "returnToDock" ) {
        Log3 $name, 2, "INDEGO set $name " . $a[1];

        INDEGO_SendCommand( $hash, "state", "returnToDock" );
    }

    # reloadMap
    elsif ( $a[1] eq "reloadMap" ) {
        Log3 $name, 2, "INDEGO set $name " . $a[1];

        INDEGO_SendCommand( $hash, "map" );
    }

    # return usage hint
    else {
        return $usage;
    }

    return;
}

###################################
sub INDEGO_Define($$) {
    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );
    my $name = $hash->{NAME};

    Log3 $name, 5, "INDEGO $name: called function INDEGO_Define()";

    if ( int(@a) < 4 ) {
        my $msg =
          "Wrong syntax: define <name> INDEGO <email> <password> [<poll-interval>]";
        Log3 $name, 4, $msg;
        return $msg;
    }

    $hash->{TYPE} = "INDEGO";

    my $email = $a[2];
    $hash->{helper}{EMAIL} = $email;

    my $password = $a[3];
    $hash->{helper}{PASSWORD} = $password;
    
    # use interval of 300 sec if not defined
    my $interval = $a[4] || 300;
    $hash->{INTERVAL} = $interval;

    unless ( defined( AttrVal( $name, "webCmd", undef ) ) ) {
        $attr{$name}{webCmd} = 'mow:pause:returnToDock';
    }

    # start the status update timer
    RemoveInternalTimer($hash);
    InternalTimer( gettimeofday() + 2, "INDEGO_GetStatus", $hash, 1 );

    return;
}

############################################################################################################
#
#   Begin of helper functions
#
############################################################################################################

###################################
sub INDEGO_SendCommand($$;$) {
    my ( $hash, $service, $type ) = @_;
    my $name        = $hash->{NAME};
    my $email       = $hash->{helper}{EMAIL};
    my $password    = $hash->{helper}{PASSWORD};
    my $timestamp   = gettimeofday();
    my $timeout     = 30;
    my $header;
    my $data;
    my $method;

    Log3 $name, 5, "INDEGO $name: called function INDEGO_SendCommand()";

    my $URL = "https://api.indego.iot.bosch-si.com/api/v1/";
    my $response;
    my $return;
    
    if ($service ne "authenticate") {
      return if !INDEGO_CheckContext($hash);
    }

    Log3 $name, 4, "INDEGO $name: REQ $service";

    if ($service eq "authenticate") {
      $URL .= $service;
      $header = "Content-Type: application/json";
      $header .= "\r\nAuthorization: Basic ";
      $header .= encode_base64("$email:$password","");
      $data = "{\"device\":\"\", \"os_type\":\"Android\", \"os_version\":\"4.0\", \"dvc_manuf\":\"unknown\", \"dvc_type\":\"unknown\"}";

    } elsif ($service eq "state") {
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "");
      $URL .= "/$service";
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");
      if (defined($type)) {
        $header .= "\r\nContent-Type: application/json";
        $data = "{\"state\":\"".$type."\"}";
        $method = "PUT";
      }

    } elsif ($service eq "firmware") {
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "");
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");

    } else {
      $URL .= "alms/";
      $URL .= ReadingsVal($name, "alm_sn", "");
      $URL .= "/$service";
      $header = "x-im-context-id: ".ReadingsVal($name, "contextId", "");

    }

    # send request via HTTP method
    Log3 $name, 5, "INDEGO $name: " . defined($method) ? $method : "POST" . " $URL (" . urlDecode($data) . ")"
      if ( defined($data) );
    Log3 $name, 5, "INDEGO $name: GET $URL"
      if ( !defined($data) );
    Log3 $name, 5, "INDEGO $name: header $header"
      if ( defined($header) );

    if ( defined($type) && $type eq "blocking" ) {
      my ($err, $data) = HttpUtils_BlockingGet(
          {
              url         => $URL,
              timeout     => 15,
              noshutdown  => 1,
              header      => $header,
              data        => $data,
              method      => $method,
              hash        => $hash,
              service     => $service,
              timestamp   => $timestamp,
          }
      );
      return $data;
    } else {
      HttpUtils_NonblockingGet(
          {
              url         => $URL,
              timeout     => $timeout,
              noshutdown  => 1,
              header      => $header,
              data        => $data,
              method      => $method,
              hash        => $hash,
              service     => $service,
              cmd         => $type,
              timestamp   => $timestamp,
              callback    => \&INDEGO_ReceiveCommand,
          }
      );
    }

    return;
}

###################################
sub INDEGO_ReceiveCommand($$$) {
    my ( $param, $err, $data ) = @_;
    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};
    my $service = $param->{service};
    my $cmd     = $param->{cmd};

    my $rc = ( $param->{buf} ) ? $param->{buf} : $param;
    my $return;
    
    Log3 $name, 5, "INDEGO $name: called function INDEGO_ReceiveCommand() rc: $rc err: $err data: $data ";

    readingsBeginUpdate($hash);

    # device not reachable
    if ($err) {

        if ( !defined($cmd) || $cmd eq "" ) {
            Log3 $name, 4, "INDEGO $name:$service RCV $err";
        } else {
            Log3 $name, 4, "INDEGO $name:$service/$cmd RCV $err";
        }

        # keep last state
        #INDEGO_ReadingsBulkUpdateIfChanged( $hash, "state", "Error" );
    }

    # data received
    elsif ($data) {
      
        if ( !defined($cmd) ) {
            Log3 $name, 4, "INDEGO $name: RCV $service";
        } else {
            Log3 $name, 4, "INDEGO $name: RCV $service/$cmd";
        }

        if ( $data ne "" ) {
            if ( $data =~ /^{/ || $data =~ /^\[/ ) {
                if ( !defined($cmd) || $cmd eq "" ) {
                    Log3 $name, 4, "INDEGO $name: RES $service - $data";
                } else {
                    Log3 $name, 4, "INDEGO $name: RES $service/$cmd - $data";
                }
                $return = decode_json( Encode::encode_utf8($data) );
            } elsif ( $service = "map" ) {
                if ( !defined($cmd) || $cmd eq "" ) {
                    Log3 $name, 4, "INDEGO $name: RES $service - $data";
                } else {
                    Log3 $name, 4, "INDEGO $name: RES $service/$cmd - $data";
                }
                $return = $data;
            } else {
                Log3 $name, 5, "INDEGO $name: RES ERROR $service\n" . $data;
                if ( !defined($cmd) || $cmd eq "" ) {
                    Log3 $name, 5, "INDEGO $name: RES ERROR $service\n$data";
                } else {
                    Log3 $name, 5, "INDEGO $name: RES ERROR $service/$cmd\n$data";
                }
                return undef;
            }
        }

        # state
        if ( $service eq "state" ) {
          if ( ref($return) eq "HASH" and !defined($cmd)) {
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "state",          INDEGO_BuildState($hash, $return->{state}));
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "mowed",          $return->{mowed});
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "mowed_ts",       FmtDateTime(int($return->{mowed_ts}/1000)));
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "mapsvgcache_ts", FmtDateTime(int($return->{mapsvgcache_ts}/1000)));
            #INDEGO_ReadingsBulkUpdateIfChanged($hash, "map_update_available", $return->{map_update_available});
            if ( ref($return->{runtime}) eq "HASH" ) {
              my $runtime = $return->{runtime};
              if ( ref($runtime->{total}) eq "HASH" ) {
                my $total = $runtime->{total};
                my $operate = $total->{operate};
                my $charge = $total->{charge};
                INDEGO_ReadingsBulkUpdateIfChanged($hash, "totalOperate", INDEGO_GetDuration($hash, $operate));
                INDEGO_ReadingsBulkUpdateIfChanged($hash, "totalCharge",  INDEGO_GetDuration($hash, $charge));
              }
              if ( ref($runtime->{session}) eq "HASH" ) {
                my $session = $runtime->{session};
                my $operate = $session->{operate};
                my $charge = $session->{charge};
                INDEGO_ReadingsBulkUpdateIfChanged($hash, "sessionOperate", INDEGO_GetDuration($hash, $operate));
                INDEGO_ReadingsBulkUpdateIfChanged($hash, "sessionCharge",  INDEGO_GetDuration($hash, $charge));
              }
            }
            readingsEndUpdate( $hash, 1 );

            INDEGO_SendCommand($hash, "map") if ($return->{map_update_available});
            INDEGO_SendCommand($hash, "firmware") if (ReadingsVal($name, "alm_name", "") eq "");
            INDEGO_SendCommand($hash, "calendar");
          }
        }
    
        # firmware
        elsif ( $service eq "firmware" ) {
          if ( ref($return) eq "HASH") {
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "alm_name",             $return->{alm_name});
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "service_counter",      $return->{service_counter});
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "bareToolnumber",       $return->{bareToolnumber});
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "alm_firmware_version", $return->{alm_firmware_version});

            readingsEndUpdate( $hash, 1 );
          }
        }

        # calendar
        elsif ( $service eq "calendar" ) {
          if ( ref($return) eq "HASH") {
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "cal", $return->{sel_cal});

            my %currentCals;
            foreach ( keys %{ $hash->{READINGS} } ) {
              $currentCals{$_} = 1 if ( $_ =~ /^cal\d_.*/ );
            }

            if ( ref($return->{cals}) eq "ARRAY" ) {
              my @cals = @{$return->{cals}};
              my $cal;
              foreach $cal (@cals) {
                my @days = @{$cal->{days}};
                my $day;
                for $day (@days) {
                  my $schedule;
                  my @slots = @{$day->{slots}};
                  my $slot;
                  for $slot (@slots) {
                    if ($slot->{En}) {
                      my $slotStr = INDEGO_GetSlotFormatted($hash, $slot->{StHr}, $slot->{StMin}, $slot->{EnHr}, $slot->{EnMin});
                      if (defined($schedule)) {
                        $schedule .= " ".$slotStr;
                      } else {
                        $schedule = $slotStr;
                      }
                    }
                  }
                  if (defined($schedule)) {
                    my $reading = "cal".$cal->{cal}."_".$day->{day}."_".INDEGO_GetDay($hash, $day->{day});
                    INDEGO_ReadingsBulkUpdateIfChanged($hash, $reading, $schedule) ;
                    delete $currentCals{$reading};
                  }
                }
              }
            }

            #remove outdated calendar information
            foreach ( keys %currentCals ) {
              delete( $hash->{READINGS}{$_} );
            }

            readingsEndUpdate( $hash, 1 );
          }
        }

        # map
        elsif ( $service eq "map" ) {
          my $map = $return;
          eval { require Compress::Zlib; };
          unless($@) {
            $map = Compress::Zlib::compress($map);
          }
          INDEGO_ReadingsBulkUpdateIfChanged($hash, ".mapsvgcache", $map );

          readingsEndUpdate( $hash, 1 );
        }

        # authenticate
        elsif ( $service eq "authenticate" ) {
          if ( ref($return) eq "HASH") {
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "contextId", $return->{contextId});
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "userId",    $return->{userId});
            INDEGO_ReadingsBulkUpdateIfChanged($hash, "alm_sn",    $return->{alm_sn});

            readingsEndUpdate( $hash, 1 );
            
            # new context received - reload state
            INDEGO_SendCommand($hash, "state");
          }
        }
    
        # all other command results
        else {
            Log3 $name, 2, "INDEGO $name: ERROR: method to handle response of $service not implemented";
        }

    } else {
        if ($rc =~ /401 Authentication was not successful/) {
            Log3 $name, 4, "INDEGO $name: renew authentication context"; 
            INDEGO_CheckContext($hash, "renew");
        }
    }

    return;
}

###################################
sub INDEGO_Undefine($$) {
    my ( $hash, $arg ) = @_;
    my $name = $hash->{NAME};

    Log3 $name, 5, "INDEGO $name: called function INDEGO_Undefine()";

    # Stop the internal GetStatus-Loop and exit
    RemoveInternalTimer($hash);

    return;
}

sub INDEGO_CheckContext($;$) {
  my ( $hash, $renew ) = @_;
  my $name = $hash->{NAME};
  my $contextId = ReadingsVal($name, "contextId", "");

  if ($contextId eq "" or defined($renew)) {
    INDEGO_SendCommand($hash, "authenticate");
    return;
  }
  
  return $contextId;
}

sub INDEGO_ReadingsBulkUpdateIfChanged($$$) {
  my ($hash,$reading,$value) = @_;
  my $name = $hash->{NAME};

  readingsBulkUpdate($hash, $reading, $value) if (ReadingsVal($name, $reading, "") ne $value);
}

sub INDEGO_GetSlotFormatted($$$$$) {
  my ($hash,$startHour,$startMin,$endHour,$endMin) = @_;
  
  return sprintf("%02d:%02d-%02d:%02d", $startHour, $startMin, $endHour, $endMin);  
}

sub INDEGO_GetDuration($$) {
  my ($hash,$duration) = @_;
  
  return sprintf("%d:%02d", int($duration/60), $duration-int($duration/60)*60);  
}

sub INDEGO_GetDay($$) {
    my ($hash,$day) = @_;
    my $days = {
        '0' => "Mon",
        '1' => "Tue",
        '2' => "Wed",
        '3' => "Thu",
        '4' => "Fri",
        '5' => "Sat",
        '6' => "Sun",
    };

    return $days->{$day};
}

sub INDEGO_BuildState($$) {
    my ($hash,$state) = @_;
    my $states = {
           '0' => "Reading status",
         '257' => "Charging",
         '258' => "Docked",
         '259' => "Docked - Software update",
         '260' => "Docked",
         '261' => "Docked",
         '262' => "Docked - Loading map",
         '263' => "Docked - Saving map",
         '513' => "Mowing",
         '514' => "Relocalising",
         '515' => "Loading map",
         '516' => "Learning lawn",
         '517' => "Paused",
         '518' => "Border cut",
         '519' => "Idle in lawn",
         '769' => "Returning to dock",
         '770' => "Returning to dock",
         '771' => "Returning to dock - Battery low",
         '772' => "Returning to dock - Calendar timeslot ended",
         '773' => "Returning to dock - Battery temp range",
         '774' => "Returning to dock",
         '775' => "Returning to dock - Lawn complete",
         '776' => "Returning to dock - Relocalising",
        '1025' => "Diagnostic mode",
        '1026' => "End of live",
       ' 1281' => "Software update"
    };

    if (defined( $states->{$state})) {
        return $states->{$state};
    } else {
        return $state;
    }
}


sub INDEGO_ShowMap($;$$) {
    my ($name,$width,$height) = @_;
    my $hash = $main::defs{$name};
    my $compress = 0;

    eval { require Compress::Zlib; };
    unless($@) {
      $compress = 1;
    } 

    my $map = ReadingsVal($name, ".mapsvgcache", "");
    my $data = $map;

    $width  = 800 if (!defined($width));
    $height = 600 if (!defined($height));

    if ($map eq "") {
      $map = INDEGO_SendCommand($hash, "map", "blocking");
      $data = $map;
      $map = Compress::Zlib::compress($map) if ($compress);
      readingsSingleUpdate($hash, ".mapsvgcache", $map, 1);
    } else {
      $data = Compress::Zlib::uncompress($data) if ($compress);
    }

    if ($data =~ /viewBox="0 0 (\d+) (\d+)"/) {
      my $factor = $1/$width;
      $height = int($2/$factor);
    }
    my $html = '<svg style="width:'.$width.'px; height:'.$height.'px;"';
    $html .= substr($data, 4);
 

    return $html;
}

1;
=pod
=begin html

<a name="INDEGO"></a>
<h3>INDEGO</h3>
<ul>
  This module controls a Bosch Indego.
  <br><br>
  <b>Define</b>
</ul>

=end html
=begin html_DE

<a name="INDEGO"></a>
<h3>INDEGO</h3>
<ul>
  Diese Module dient zur Steuerung eines Bosch Indego
  <br><br>
  <b>Define</b>
</ul>

=end html_DE
=cut