#!/bin/bash

## Install script for Consoled Utilities
##
## $Id$

echo "Checking Perl toolkit..."
cpan -i Module::Load Module::Load::Conditional 2>&1 >cpan_update.log
echo "Configuring..."
perl Makefile.PL
echo "Installing..."
make install
echo "Done."
