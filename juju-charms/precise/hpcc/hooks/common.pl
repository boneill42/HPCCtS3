#!/usr/bin/perl
$service='tlh-hpcc';
$HomePath="/home/ubuntu";

$FilePartsFolder="/var/lib/HPCCSystems/hpcc-data/thor";

$cpfs3_logname = "$HomePath/tlh_hpcc_cpFilesFromS3.log";
$cpfs3_DoneAlertFile = "$HomePath/done_cpFilesFromS3";
$cp2s3_logname = "$HomePath/tlh_hpcc_cpFiles2S3.log";
$cp2s3_DoneAlertFile = "$HomePath/done_cpFiles2S3";

$MetadataFolder='/home/ubuntu/metadata';

$dfuplus='/opt/HPCCSystems/bin/dfuplus';

$jujutools='/var/lib/juju/tools';
$jujulogpath=$jujutools.'/'.`ls -l $jujutools|egrep "^d"|sed "s/^.........................................//"`;

# Get hpcc juju unit number
$_=`ls -l /var/log/juju/*`;
$juju_unit_number = $1 if /unit-${service}-(\d+).log/;

$juju_ip_file='/var/lib/HPCCSystems/charm/ip_file.txt';

sub openLog{
my ( $logname )=@_;

     $logname = "-" if $logname eq '';
     if ( ! -e $logname ){
        open(LOG,">$logname") || die "Can't open for output \"$logname\"\n";
     }
     else{
        open(LOG,">>$logname") || die "Can't open for output \"$logname\"\n";
     }
}

sub printLog{
my ( $logname, $text2print )=@_;
  print LOG $text2print;
}

sub thor_nodes_ips{
  # Gets a list of private ip addresses for all slave nodes that is ordered 
  #  such that the 1st slave node is 1st, the 2nd slave node is 2nd, etc.
  @slave_pip=split(/\n/,`cat $juju_ip_file|egrep "[0-9]"`);
  $master_pip=shift @slave_pip;
  $master_pip=~s/;//;
  for( my $i=0; $i < scalar(@slave_pip); $i++){
     my $slave_number=$i+1;
     printLog($cpfs3_logname,"In thor_nodes_ips. slave_pip\[$slave_number\]=\"$slave_pip[$i]\n");
  }
return ($master_pip, @slave_pip);
}

sub get_this_nodes_private_ip{
my ($logname)=@_;
  # Get the private ip address of this slave node 
  $_=`ifconfig`;
  s/^.*?eth0/eth0/s;
  s/\n\s*\n.*$//s;

  my $ThisNodesPip='99.99.99.99';
  if ( /inet addr:(\d+(?:\.\d+){3})\b/s ){
     $ThisNodesPip = $1;
     printLog($logname,"In get_this_nodes_private_ip.pl. ThisNodesPip=\"$ThisNodesPip\"\n");
  }
  else{
     printLog($logname,"In get_this_nodes_private_ip. Could not file ThisNodesPip in ifconfig's output. EXITing\n");
     exit 1;
  }
return $ThisNodesPip;
}

sub get_thor_slave_number{
my ($ThisSlaveNodesPip,$slave_pip_ref)=@_;
my @slave_pip = @$slave_pip_ref;
  # Find the private ip address of @slave_pip that matches this
  #  slave node's ip address. When found index, where index begins with 1, into @all_slave_nod_ips will
  #     be $ThisSlaveNodeId.
  my $thor_slave_number='';
  my $FoundThisSlaveNodeId=0;
  for( my $i=0; $i < scalar(@slave_pip); $i++){
     if ( $slave_pip[$i] eq "$ThisSlaveNodesPip;" ){
        $thor_slave_number=$i+1;
        printLog($cpfs3_logname,"In get_thor_slave_number. thor_slave_number=\"$thor_slave_number\"\n");
        $FoundThisSlaveNodeId=1;
        last;
     }
  }  
 
  if ( $FoundThisSlaveNodeId==0 ){
      printLog($cpfs3_logname,"Could not find thor slave number for this slave ($ThisSlaveNodesPip). EXITING without copying file parts to S3.\n");
      exit 1;
  }
return $thor_slave_number;
}

sub get_s3cmd_config{
my ( $juju_unit_number )=@_;
# Setup s3cmd configuration file if it exists.
my $cfg = ( -e "/var/lib/juju/agents/unit-${service}-$juju_unit_number/charm/hooks/.s3cfg" )? "--config=/var/lib/juju/agents/unit-${service}-$juju_unit_number/charm/hooks/.s3cfg" : '';

printLog($cpfs3_logname,"In get_s3cmd_config. cfg=\"$cfg\"\n");

if ( $cfg eq '' ){
   printLog($cpfs3_logname,"In get_s3cmd_config. ERROR. The s3cmd config file was NOT found for juju_unit_number=\"$juju_unit_number\".\n");
   exit 1;
}

return $cfg;
}

sub FilesOnThor{
my ( $master_pip )=@_;
  # Get list of files on thor
  my @file=split(/\n/,`/opt/HPCCSystems/bin/dfuplus server=$master_pip action=list name=*`);
  shift @file;
  if ( scalar(@file)==0 ){
     printLog($cp2s3_logname,"In isFilesOnThor. There are no files on this thor.\n");
  }
return @file;
}

sub cpAllFilePartsOnS3{
my ( $thor_folder, $s3folder )=@_;
   printLog($cpfs3_logname,"DEBUG: Entering cpAllFilePartsOnS3. thor_folder=\"$thor_folder\", s3folder=\"$s3folder\"\n");
   my $entries=`sudo s3cmd $cfg ls $s3folder/*`;

   my @entry=split(/\n/s,$entries);
   @entry = grep(! /^\s*$/,@entry);
   foreach my $e (@entry){
     printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. entry=\"$e\"\n");
   }

   my $found_at_least_one_part = 0;
   foreach (@entry){
      # Is this entry a directory?
      if ( s/^\s*DIR\s*// ){
         s/\/\s*$//;
         printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. \$_=\"$_\"\n");
         my $subfolder = $1 if /\/([^\/]+)\s*$/;
         printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. subfolder=\"$subfolder\"\n");
         
         if ( ! -e $thor_folder ){
            printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. Saw DIR. system(\"sudo mkdir $thor_folder\")\n");
            system("sudo mkdir $thor_folder"); 
         }
         
         my $newfolder="$thor_folder/$subfolder";
         printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. Calling cpAllFilePartsOnS3(\"$newfolder\",\"$_\");\n");
         cpAllFilePartsOnS3($newfolder,$_);
      }
      else{
         $found_at_least_one_part = 1;
      }
   }

   if ( $found_at_least_one_part ){
      printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. Found at least one file part. So, copying it from S3 to node.\n");
      if ( ! -e $thor_folder ){
         printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. system(\"sudo mkdir $thor_folder\")\n");
         system("sudo mkdir $thor_folder"); 
      }
      printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. system(\"cd $thor_folder;sudo s3cmd $cfg get $s3folder/*\")\n");
      system("cd $thor_folder;sudo s3cmd $cfg get $s3folder/* > /dev/null 2> /dev/null");
   }
   else{
      printLog($cpfs3_logname,"DEBUG: In cpAllFilePartsOnS3. NO FILE PARTS FOR THE FOLDER, $thor_folder.\n");
   }
   printLog($cpfs3_logname,"DEBUG: Leaving cpAllFilePartsOnS3\n");
}

1;