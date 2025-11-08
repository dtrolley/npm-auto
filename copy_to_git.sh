#!/bin/bash

CWD=`pwd`

rm -Rf $CWD/src/npm-auto/usr/local/emhttp/plugins/npm-auto/*
cp /usr/local/emhttp/plugins/npm-auto/* $CWD/src/npm-auto/usr/local/emhttp/plugins/npm-auto -R -v -p
chmod -R 0755 ./
chown -R root:root ./