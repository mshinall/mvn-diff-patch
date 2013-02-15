#!/usr/bin/perl -w
#
# build a tar of only the changed items substituting the compiled artifacts if
# necessary 
#

use strict;
use warnings;
use File::Path;
use File::Copy;
use File::Basename;

use 5.008_008;

my $VERSION = "1.09";
my $RM_TEMP_DIR = 1; #0=leave temp dir intact, #1=delete temp dir when finished
my $DO_MVN_BUILD = 0; #0=no mvn build, #1=do mvn build

my $USAGE = <<_END_;
Usage: mvndiffpatch.pl DIFF_BRANCH PROJECT_DIR BUILD_NAME ARCHIVE_NAME
    DIFF_BRANCH    Diff from this branch
    PROJECT_DIR    Directory that contains the maven project
    BUILD_NAME     maven project final build name
    ARCHIVE_NAME   Name of the .tgz file to be generated
_END_


#BEGIN MAIN SCRIPT
#stop if less than two args provided
(scalar(@ARGV) > 3) or die("${USAGE}\n");
my ($branch1, $basedir, $bldname, $archive) = @ARGV;
printf("perl: v%vd\n", $^V);
print("script version: ${VERSION}\n");
print("args: \n\t'" . join(qq(',\n\t'), @ARGV) . "'\n");

$basedir =~ s|/$||;
$basedir .= '/';

(-d $basedir) or die("${USAGE}\n");

my $branch2 = getCurrentBranch();

my $timestamp = getTimestamp();

my $srcdir = "${basedir}src/main/";
my $blddir = "${basedir}target/${bldname}/";
my $tmpdirname = "";
if($archive) {
    $tmpdirname = "${archive}"; 
} else {
    $tmpdirname = "diff-${timestamp}";  
}
my $arcname = "${tmpdirname}.tgz";
my $tmpdir = "${tmpdirname}/";    
my $trgdir = "${tmpdir}${bldname}/";
my $arcbasedir = File::Basename::dirname($arcname);
my $tmpbasename = File::Basename::basename($tmpdirname);

my $updscr = "${tmpdir}update.sh";
my $updsrc = q(${1}/);
my $updtrg = q(${2}/);

my @delfiles = ();
my @modfiles = ();

print <<_END_;

using the following:
    branch1: ${branch1}
    branch2: ${branch2}
    basedir: ${basedir}
    bldname: ${bldname}
    archive: ${arcname}    
_END_

#create temp directories
File::Path::mkpath($tmpdir);
File::Path::mkpath($trgdir);

#do maven build
doMvnBuild();

#get an array of lines from git diff
my @diffLines = doGitDiff();

#process the files in the git diff
processFiles(@diffLines);

#stop if nothing was changed
(scalar(@delfiles + @modfiles) > 0) or stop("No changes found. Stopping.\n");

#generate the update script
generateUpdScr();

#generate the .tgz archive file containing the changed build artifacts and
#update script
generateArchive();

#remove the temporary directory
rmTmpDir();

#done
print("\nDiff saved to '${arcname}'\n");
print("\nDone.\n\n");
#END MAIN SCRIPT

#### SUBS ####
sub stop {
    print(@_);
    exit(0);
}

sub getTimestamp {
    my $timestamp = localtime();
    $timestamp =~ s/\W+/-/g;
    return $timestamp;
}

sub rmTmpDir {
    if($RM_TEMP_DIR) {
        print("Removing temp directory '${tmpdir}'...\n");
        File::Path::rmtree($tmpdir);
    }
}

sub generateUpdScr {
    my $fh;
    open($fh, ">${updscr}");
    
    print $fh <<_END_;
#!/bin/bash
# generated on ${timestamp}

if [ \$# -lt 2 ]; then
    echo "Usage: ${updscr} SOURCE_DIR INSTALL_DIR"
    exit 1
fi

_END_

    if(scalar(@delfiles) > 0) {
        print $fh "echo \"Deleting removed files from '${updtrg}'...\"\n";
        foreach my $file (@delfiles) {
            print $fh "/bin/rm \"${updtrg}${file}\"\n";
        }
    }

    print $fh <<_END_;
    
echo "Copying new and modified files from '${updsrc}' to '${updtrg}'..."
/bin/cp -rv -t ${updtrg} ${updsrc}*

echo 'Done.'

_END_
    
    close($fh);
    chmod(0777, $updscr);
}

sub docmd {
    my ($cmd) = @_;
    print("doing shell command: '${cmd}'...\n");
    my $val = `${cmd}`;
    return $val;
}

sub added {
    my ($file) = @_;
    push(@modfiles, $file);    
    print("[A] Found new file '" . $file->{filename} . "'\n");
    copySources($file);    
}

sub modified {
    my ($file) = @_;
    print("[M] Found modified file '" . $file->{filename} . "'\n");
    push(@modfiles, $file);    
    copySources($file);
}

sub deleted {
    my ($file) = @_;
    print("[D] Found deleted file '" . $file->{filename} . "'\n");        
    return unless $file;
    for my $item (@{$file->{remove}}) {
        push(@delfiles, $item);
    }
}

sub copySources {
    my ($file) = @_;    
    return unless $file;
    File::Path::mkpath($file->{target});
    for my $item (@{$file->{source}}) {
        File::Copy::copy($item, $file->{target});
    }
}

sub process {
    my ($filename) = @_;
    #print("filename=" . $filename . "\n");
    $filename =~ /^(.*)\/([^\/.]*)\.(\w*)$/ && do {
        my $path = $1 . '/';
        return undef if ($path =~ m|/src/test/|);
        my $name = $2;
        return undef unless $name;        
        my $extn = $3;
        return undef unless $extn;

        #print("path: ${path}\n");
        #print("name: ${name}\n");
        #print("extn: ${extn}\n");


        my $file = {};
        $file->{filename} = $filename;
        
        $extn =~ /properties|xml/ && do {
            $path =~ m|^${srcdir}resources/| && do {
                my $trgRoot = $path;
                $trgRoot =~ s|^${srcdir}resources/|${trgdir}WEB-INF/classes/|;
                
                $file->{source} = [$filename];
                $file->{target} = $trgRoot;
                $file->{remove} = ["WEB-INF/classes/${name}.${extn}"];            
                return $file;
            }
        };        
           
        $extn eq 'java' && do {
            my $srcRoot = $path;
            $srcRoot =~ s|^${srcdir}java/|${blddir}WEB-INF/classes/|;
            
            my $trgRoot = $path;
            $trgRoot =~ s|^${srcdir}java/|${trgdir}WEB-INF/classes/|;
            
            my $remRoot = $path;
            $remRoot =~ s|^${srcdir}java/|WEB-INF/classes/|;
            
            $file->{source} = [
                "${srcRoot}${name}.class",
                glob("${srcRoot}${name}\$*.class"),
            ];
            $file->{target} = $trgRoot;
            $file->{remove} = [
                "${remRoot}${name}.class",
                "${remRoot}${name}\\\$*.class"
            ];
            return $file;
        };
        
        $extn eq 'less' && do {
            my $srcRoot = $path;
            $srcRoot =~ s|^${srcdir}bootstrap/(.*)/|${blddir}css/${1}.css|;
            $file->{source} = [$srcRoot];
            $file->{target} = "${trgdir}css";
            $file->{remove} = ["css/${1}.css"];
            return $file;            
        };

        $path =~ m|^${srcdir}webapp/| && do {
            my $trgRoot = $path;
            $trgRoot =~ s|^${srcdir}webapp/|${trgdir}|;
            
            my $remRoot = $path;
            $remRoot =~ s|^${srcdir}webapp/|/|;
            
            $file->{source} = [$filename];
            $file->{target} = $trgRoot;
            $file->{remove} = ["${remRoot}${name}.${extn}"];
            return $file;        
        };
        
        $path =~ m|^${srcdir}| && do {
            my $trgRoot = $path;
            $trgRoot =~ s|^${srcdir}|${trgdir}|;
            
            my $remRoot = $path;
            $remRoot =~ s|^${srcdir}|/|;
            
            $file->{source} = [$filename];
            $file->{target} = $trgRoot;
            $file->{remove} = ["${remRoot}${name}.${extn}"];
            return $file;        
        };        
        
        #print($filename . "\n");
        
    };
    return undef;
}

sub doGitDiff {
    print("\nGenerating git diff...\n");
    my $diffCmd = "git diff --name-status --relative ${branch1}...${branch2}";
    my $diff = docmd($diffCmd);
    #print("diff:\n" . $diff . "\n");
    my @lines = split('\n', $diff);
}

sub doMvnBuild {
    if($DO_MVN_BUILD) {
        print("\nBuilding maven project, please wait...\n");
        my $mvnCmd = "mvn -f '${$basedir}pom.xml' clean package";
        docmd($mvnCmd);
    }    
}

sub processFiles {
    my (@lines) = @_;
    print("\nProcessing changed files...\n");
    foreach my $line (@lines) {
        my ($mod, $filename) = split('\s+', $line, 2);
        my $file = process("${basedir}${filename}");
        #print("file: ${basedir}${filename}\n");
        next if !$file;
        
=pod COMMENT

A|C|D|M|R|T|U|X|B
A  Added
C  Copied
D  Deleted
M  Modified
R  Renamed
T  have their type (i.e. regular file, symlink, submodule, ...) changed
U  are Unmerged
X  are Unknown
B  have had their pairing Broken

=cut
        
        $mod =~ /A/ && do { added($file); };    
        $mod =~ /D/ && do { deleted($file); };            
        $mod =~ /M/ && do { modified($file); };
    
        #not implemented yet
        #$mod =~ /C/ && do {}; #copied
        #$mod =~ /R/ && do {}; #renamed
        #$mod =~ /T/ && do {}; #type changed
        #$mod =~ /U/ && do {}; #unmerged
        #$mod =~ /X/ && do {}; #unknown
        #$mod =~ /B/ && do {}; #broken pairing
    }
}

sub generateArchive {
    print("\nGenerating archive file '${arcname}'...\n");
    my $tarCmd = "/bin/tar -zcf '${arcname}' -C '${arcbasedir}' '${tmpbasename}'";
    docmd($tarCmd);
}

sub getCurrentBranch {
    print("\nGetting the current branch name...\n");
    my $brCmd = "cd ${basedir}; git status -unormal | head -1";
    my $branch = docmd($brCmd);
    $branch =~ s/^#\s*On branch ([\w-]+)\s*$/$1/;
    $branch or die("Could not determine the name of the current git branch.
        Stopping.\n");
    print("    ${branch}\n");
    return $branch;
}

1;




