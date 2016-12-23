#!/bin/bash
set -e

echo "mainframer v1.0.2"

echo "Start time: $( date )"
BUILD_START_TIME=`date +%s`

# You can run it from any directory.
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR=$DIR
PROJECT_DIR_NAME="$( basename "$PROJECT_DIR")"

# Read config variables from local.properties.
REMOTE_BUILD_MACHINE=$(awk -F "=" '/remote_build.machine/ {print $2}' "$PROJECT_DIR/local.properties")
LOCAL_GZIP_LEVEL=$(awk -F "=" '/remote_build.local_gzip_level/ {print $2}' "$PROJECT_DIR/local.properties")
REMOTE_GZIP_LEVEL=$(awk -F "=" '/remote_build.remote_gzip_level/ {print $2}' "$PROJECT_DIR/local.properties")
REMOTE_SSH_PORT=$(awk -F "=" '/remote_build.ssh_port/ {print $2}' "$PROJECT_DIR/local.properties")
USE_RSYNC=$(awk -F "=" '/build.use_rsync/ {print $2}' "$PROJECT_DIR/local.properties")

if [ -z "$LOCAL_GZIP_LEVEL" ]; then
	LOCAL_GZIP_LEVEL=1
fi

if [ -z "$REMOTE_GZIP_LEVEL" ]; then
	REMOTE_GZIP_LEVEL=1
fi

if [ -z "$REMOTE_SSH_PORT" ]; then
	REMOTE_SSH_PORT=22
fi

if [ -z "$REMOTE_BUILD_MACHINE" ]; then
	echo "Please specify remote build machine in local.properties"
	exit 1
fi

if [ -z "$USE_RSYNC" ]; then
	USE_RSYNC=false
fi

BUILD_COMMAND="$@"

if [ -z "$BUILD_COMMAND" ]; then
	echo "Please pass build command."
	exit 1
fi

# Create build folder in case if it does not exist.
mkdir -p "$PROJECT_DIR"/build

# Remove previous archives of the project.
rm -f "$PROJECT_DIR"/build/project_for_remote_build.tar "$PROJECT_DIR"/build/remotely_built_project.tar

# Archiver.

DETECT_ARCHIVER="if type 'pigz' > /dev/null; then echo 'pigz'; else echo 'gzip'; fi"
LOCAL_ARCHIVER=`eval $DETECT_ARCHIVER`

# Archive project.
pushd "$PROJECT_DIR"
LOCAL_ARCHIVE_COMMAND="tar \
-c \
--exclude='build/project_for_remote_build.tar' \
--exclude='local.properties' \
--exclude='.gradle' \
--exclude='.idea' \
--exclude='.git' \
--exclude='artifacts' \
--exclude='captures' \
--exclude='build' \
--exclude='*/build' \
."

RSYNC_TO_REMOTE="rsync -av --delete \
--exclude='**/.git/' \
--exclude='**/local.properties' \
--exclude='.idea' \
--exclude='.gradle' \
--exclude='**/build' \
-e 'ssh -p $REMOTE_SSH_PORT' ./ $REMOTE_BUILD_MACHINE:~/$PROJECT_DIR_NAME/"

RSYNC_FROM_REMOTE="rsync --delete -av --partial \
--exclude='**/.git/' \
--exclude='**/local.properties' \
--exclude='.idea' \
--exclude='.gradle' \
-e 'ssh -p $REMOTE_SSH_PORT' $REMOTE_BUILD_MACHINE:~/$PROJECT_DIR_NAME/ ./"

if [ $LOCAL_GZIP_LEVEL = "0" ]; then
	LOCAL_ARCHIVE_COMMAND+=" > build/project_for_remote_build.tar"
	REMOTE_UNARCHIVE_COMMAND="tar -xf project_for_remote_build.tar -C $PROJECT_DIR_NAME"
else
	LOCAL_ARCHIVE_COMMAND+=" | $LOCAL_ARCHIVER -$LOCAL_GZIP_LEVEL > build/project_for_remote_build.tar"
	REMOTE_UNARCHIVE_COMMAND="\$REMOTE_ARCHIVER -d < project_for_remote_build.tar | tar -xf - -C $PROJECT_DIR_NAME"
fi

if [ $USE_RSYNC == false ]; then
	eval $LOCAL_ARCHIVE_COMMAND
fi
popd

# Prepare remote archive and local unarchive commands.
REMOTE_ARCHIVE_COMMAND="tar \
-c \
--exclude='kotlin' \
--exclude='tmp' \
build/ */build"

if [ $REMOTE_GZIP_LEVEL = "0" ]; then
	REMOTE_ARCHIVE_COMMAND+=" > remotely_built_project.tar"
	LOCAL_UNARCHIVE_COMMAND="tar -xf build/remotely_built_project.tar -C ./"
else
	REMOTE_ARCHIVE_COMMAND+=" | \$REMOTE_ARCHIVER -$REMOTE_GZIP_LEVEL > remotely_built_project.tar"
	LOCAL_UNARCHIVE_COMMAND="$LOCAL_ARCHIVER -d < build/remotely_built_project.tar | tar -xf - -C ./"
fi

# Transfer archive to remote machine.

if [ $USE_RSYNC == false ]; then
	scp -P "$REMOTE_SSH_PORT" "$PROJECT_DIR/build/project_for_remote_build.tar" $REMOTE_BUILD_MACHINE:~/
else
	eval $RSYNC_TO_REMOTE
fi

# Build project on a remote machine and then archive it.
if [ $USE_RSYNC == false ]; then
	ssh $REMOTE_BUILD_MACHINE -p "$REMOTE_SSH_PORT" \
	"set -xe && \
	export ANDROID_HOME=/home/kokeroulis/Android/Sdk \
	export REMOTE_ARCHIVER=\`eval \"$DETECT_ARCHIVER\"\` && \
	cd ~ && \
	mkdir -p $PROJECT_DIR_NAME && \
	rm -rf $PROJECT_DIR_NAME/build/remotely_built_project.tar $PROJECT_DIR_NAME/*/src && \
	$REMOTE_UNARCHIVE_COMMAND && \
	cd $PROJECT_DIR_NAME && \
	$BUILD_COMMAND && \
	$REMOTE_ARCHIVE_COMMAND"
else
	ssh $REMOTE_BUILD_MACHINE -p "$REMOTE_SSH_PORT" \
	"set -xe && \
	export ANDROID_HOME=/home/kokeroulis/Android/Sdk && \
	cd ~ && \
	mkdir -p $PROJECT_DIR_NAME && \
	cd $PROJECT_DIR_NAME && \
	$BUILD_COMMAND"
fi

# Clean local build dirs.
if [ $USE_RSYNC == false ]; then
	rm -rf "$PROJECT_DIR"/build "$PROJECT_DIR"/*/build
	mkdir -p "$PROJECT_DIR/build/"
fi

# Copy build results from remote machine to local.
if [ $USE_RSYNC == false ]; then
	scp -P "$REMOTE_SSH_PORT" "$REMOTE_BUILD_MACHINE":~/"$PROJECT_DIR_NAME"/remotely_built_project.tar "$PROJECT_DIR/build/"
	# Unarchive build results.
	pushd "$PROJECT_DIR"
	eval "$LOCAL_UNARCHIVE_COMMAND"
	popd
else
	eval $RSYNC_FROM_REMOTE
fi

BUILD_END_TIME=`date +%s`
echo "End time: $( date )"
echo "Whole process took `expr $BUILD_END_TIME - $BUILD_START_TIME` seconds."
