#!/bin/bash

# fail fast
set -e

SUPPORT_DIR=`dirname $(readlink -f $0)`
BUILD_DIR=$SUPPORT_DIR/../build
VULCAN_CONFIG_FILE=$SUPPORT_DIR/config.sh
VARIABLES_FILE=$SUPPORT_DIR/../variables.sh
APP_BUNDLE_TGZ_FILE=app-bundle.tar.gz

# include the vulcan config file
if [ ! -e $VULCAN_CONFIG_FILE ]; then
    echo "Cannot find ./support/config.sh, so I won't automatically upload the bundles to S3 for you"
    S3_ENABLED=0
else
    S3_ENABLED=1

    . $VULCAN_CONFIG_FILE

    if [ -z "$BUILDPACK_S3_BUCKET" ]; then
        echo "\$BUILDPACK_S3_BUCKET variable not found in $VULCAN_CONFIG_FILE, exiting..."
        exit 1;
    fi

    if [ -z `which s3cmd` ]; then
        echo "Cannot find s3cmd, please install it, exiting..."
        exit 1;
    fi

    S3CMD_HAS_ACCESS=`s3cmd ls s3://$BUILDPACK_S3_BUCKET 2>&1 > /dev/null`
    if [ $? = "1" ]; then
        echo "s3cmd has not been setup with access to $BUILDPACK_S3_BUCKET."
        echo "Please run s3cmd --configure to set it up."
        echo "Exiting..."
        exit 1;
    fi
fi

. $VARIABLES_FILE

# What are we building?
BUILD_APACHE=
BUILD_ANT=
BUILD_PHP=
BUILD_NEWRELIC=
BUILD_IS_VALID=

while [ $# -gt 0 ]
do
    case "$1" in
        all)
            BUILD_IS_VALID=1
            BUILD_APACHE=1
            BUILD_ANT=1
            BUILD_PHP=1
            BUILD_NEWRELIC=1
            ;;

        apache | php)
            BUILD_IS_VALID=1
            # Apache build includes php in order to get mod php
            BUILD_APACHE=1
            BUILD_PHP=1
            ;;
        ant)
            BUILD_IS_VALID=1
            BUILD_ANT=1
            ;;
        newrelic)
            BUILD_IS_VALID=1
            BUILD_NEWRELIC=1
            ;;
    esac
    shift
done

if [ -z $BUILD_IS_VALID ]; then
    echo "No packages specified. Please specify at least one of: all, apache, ant, php, newrelic"
    exit 1;
fi

# Assemble the vulcan command
BUILD_COMMAND=()
if [ $BUILD_APACHE ]; then
   BUILD_COMMAND+=("./package_apache.sh")
fi

if [ $BUILD_PHP ]; then
   BUILD_COMMAND+=("./package_php.sh")
fi

if [ $BUILD_NEWRELIC ]; then
    BUILD_COMMAND+=("./package_newrelic.sh")
fi

if [ ! -z $BUILD_COMMAND ]; then
    if [ "${#BUILD_COMMAND[@]}" = "1" ]; then
        VULCAN_COMMAND=${BUILD_COMMAND[@]}
    else
        VULCAN_COMMAND=$(printf "%s && " "${BUILD_COMMAND[@]}")
    fi
fi

# Prepare for the build
if [ -e $BUILD_DIR ]; then
    rm -Rf $BUILD_DIR
fi
mkdir -p $BUILD_DIR

# Copy the variables file
cp $VARIABLES_FILE $BUILD_DIR/variables.sh

# Copy the package scripts
cp $SUPPORT_DIR/package_* $BUILD_DIR/

if [ ! -z "$VULCAN_COMMAND" ]; then
    vulcan build -v -s $BUILD_DIR/ -p /app -c "$VULCAN_COMMAND echo Finished." -o $BUILD_DIR/$APP_BUNDLE_TGZ_FILE

    echo
    echo
    echo -n "*** Did the build succeed? (Y/n)"
    read IS_SUCCESSFUL
    if [ "$IS_SUCCESSFUL" = "n" ] || [ "$IS_SUCCESSFUL" = "N" ]; then
        echo "Exiting..."
        exit 1;
    fi

    # Extract the app bundle
    cd $BUILD_DIR/
    tar xf $APP_BUNDLE_TGZ_FILE

    # Upload Apache to S3
    if [ $BUILD_APACHE ]; then
        tar zcf $APACHE_TGZ_FILE apache logs/apache*
        if [ $S3_ENABLED ]; then
            s3cmd put --acl-public $APACHE_TGZ_FILE s3://$BUILDPACK_S3_BUCKET/$APACHE_TGZ_FILE
        else
            echo "Apache available at: $APACHE_TGZ_FILE"
        fi
    fi

    # Upload PHP to S3
    if [ $BUILD_PHP ]; then
        tar zcf $PHP_TGZ_FILE php
        if [ $S3_ENABLED ]; then
            s3cmd put --acl-public $PHP_TGZ_FILE s3://$BUILDPACK_S3_BUCKET/$PHP_TGZ_FILE
        else
            echo "PHP available at: $PHP_TGZ_FILE"
        fi
    fi

    # Upload new relic to S3
    if [ $BUILD_NEWRELIC ]; then
        tar zcf $NEWRELIC_TGZ_FILE newrelic logs/newrelic*
        if [ $S3_ENABLED ]; then
            s3cmd put --acl-public $NEWRELIC_TGZ_FILE s3://$BUILDPACK_S3_BUCKET/$NEWRELIC_TGZ_FILE
        else
            echo "New Relic available at: $NEWRELIC_TGZ_FILE"
        fi
    fi
fi

# Grab ant and upload to S3
if [ $BUILD_ANT ]; then
    cd $BUILD_DIR/

    # Download ant
    curl -L -s http://apache.sunsite.ualberta.ca//ant/binaries/apache-ant-${ANT_VERSION}-bin.tar.gz | tar zx
    mv apache-ant-${ANT_VERSION} ant

    # Download ant-contrib
    curl -L -s http://sourceforge.net/projects/ant-contrib/files/ant-contrib/${ANT_CONTRIB_VERSION}/ant-contrib-${ANT_CONTRIB_VERSION}-bin.tar.gz/download | tar zx
    mv ant-contrib/ant-contrib-${ANT_CONTRIB_VERSION}.jar ant/ant-contrib.jar

    tar zcf $ANT_TGZ_FILE ant
    if [ $S3_ENABLED ]; then
        s3cmd put --acl-public $ANT_TGZ_FILE s3://$BUILDPACK_S3_BUCKET/$ANT_TGZ_FILE
    else
        echo "Ant available at: $NEWRELIC_TGZ_FILE"
    fi
fi

# Update the manifest file
cd $BUILD_DIR/
s3cmd get --force s3://$BUILDPACK_S3_BUCKET/$MANIFEST_FILE
TGZ_FILES=( "$APACHE_TGZ_FILE" "$ANT_TGZ_FILE" "$PHP_TGZ_FILE" "$NEWRELIC_TGZ_FILE" )
for TGZ_FILE in "${TGZ_FILES[@]}"; do
    if [ -e $TGZ_FILE ]; then
        # Remove the current md5 from the manifest
        grep -v "$TGZ_FILE" $MANIFEST_FILE > manifest.tmp
        mv manifest.tmp $MANIFEST_FILE

        # Add the new md5
        md5sum $TGZ_FILE >> $MANIFEST_FILE
    fi
done

if [ $S3_ENABLED ]; then
    s3cmd put --acl-public $MANIFEST_FILE s3://$BUILDPACK_S3_BUCKET/$MANIFEST_FILE
else
    echo "Manifest available at: $MANIFEST_FILE"
fi
