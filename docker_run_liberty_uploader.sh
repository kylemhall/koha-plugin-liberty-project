#!/bin/bash

PDFS_DIR=$1
TMP_DIR=$2

COMMAND="docker run -v $PDFS_DIR:/ORIGIN -v $TMP_DIR:/DESTINATION liberty-uploader"

echo $COMMAND
eval $COMMAND

