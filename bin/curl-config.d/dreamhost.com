#! /bin/sh
#***************************************************************************
#                                  _   _ ____  _
#  Project                     ___| | | |  _ \| |
#                             / __| | | | |_) | |
#                            | (__| |_| |  _ <| |___
#                             \___|\___/|_| \_\_____|
#
# Copyright (C) 2001 - 2012, Daniel Stenberg, <daniel@haxx.se>, et al.
#
# This software is licensed as described in the file COPYING, which
# you should have received as part of this distribution. The terms
# are also available at http://curl.haxx.se/docs/copyright.html.
#
# You may opt to use, copy, modify, merge, publish, distribute and/or sell
# copies of the Software, and permit persons to whom the Software is
# furnished to do so, under the terms of the COPYING file.
#
# This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
# KIND, either express or implied.
#
###########################################################################

prefix=/home/jkeroes
exec_prefix=${prefix}
includedir=${prefix}/include
cppflag_curl_staticlib=

usage()
{
    cat <<EOF
Usage: curl-config [OPTION]

Available values for OPTION include:

  --built-shared says 'yes' if libcurl was built shared
  --ca        ca bundle install path
  --cc        compiler
  --cflags    pre-processor and compiler flags
  --checkfor [version] check for (lib)curl of the specified version
  --configure the arguments given to configure when building curl
  --features  newline separated list of enabled features
  --help      display this help and exit
  --libs      library linking information
  --prefix    curl install prefix
  --protocols newline separated list of enabled protocols
  --static-libs static libcurl library linking information
  --version   output version information
  --vernum    output the version information as a number (hexadecimal)
EOF

    exit $1
}

if test $# -eq 0; then
    usage 1
fi

while test $# -gt 0; do
    case "$1" in
    # this deals with options in the style
    # --option=value and extracts the value part
    # [not currently used]
    -*=*) value=`echo "$1" | sed 's/[-_a-zA-Z0-9]*=//'` ;;
    *) value= ;;
    esac

    case "$1" in
    --built-shared)
        echo yes
        ;;

    --ca)
        echo ""/etc/ssl/certs/ca-certificates.crt""
        ;;

    --cc)
        echo "gcc"
        ;;

    --prefix)
        echo "$prefix"
        ;;

    --feature|--features)
        for feature in SSL IPv6 UnixSockets libz IDN NTLM NTLM_WB ""; do
            test -n "$feature" && echo "$feature"
        done
        ;;

    --protocols)
        for protocol in DICT FILE FTP FTPS GOPHER HTTP HTTPS IMAP IMAPS LDAP LDAPS POP3 POP3S RTSP SMB SMBS SMTP SMTPS TELNET TFTP; do
            echo "$protocol"
        done
        ;;

    --version)
        echo libcurl 7.40.0
        exit 0
        ;;

    --checkfor)
        checkfor=$2
        cmajor=`echo $checkfor | cut -d. -f1`
        cminor=`echo $checkfor | cut -d. -f2`
        # when extracting the patch part we strip off everything after a
        # dash as that's used for things like version 1.2.3-CVS
        cpatch=`echo $checkfor | cut -d. -f3 | cut -d- -f1`
        checknum=`echo "$cmajor*256*256 + $cminor*256 + ${cpatch:-0}" | bc`
        numuppercase=`echo 072800 | tr 'a-f' 'A-F'`
        nownum=`echo "obase=10; ibase=16; $numuppercase" | bc`

        if test "$nownum" -ge "$checknum"; then
          # silent success
          exit 0
        else
          echo "requested version $checkfor is newer than existing 7.40.0"
          exit 1
        fi
        ;;

    --vernum)
        echo 072800
        exit 0
        ;;

    --help)
        usage 0
        ;;

    --cflags)
        if test "X$cppflag_curl_staticlib" = "X-DCURL_STATICLIB"; then
          CPPFLAG_CURL_STATICLIB="-DCURL_STATICLIB "
        else
          CPPFLAG_CURL_STATICLIB=""
        fi
        if test "X${prefix}/include" = "X/usr/include"; then
          echo "$CPPFLAG_CURL_STATICLIB"
        else
          echo "${CPPFLAG_CURL_STATICLIB}-I${prefix}/include"
        fi
        ;;

    --libs)
        if test "X${exec_prefix}/lib" != "X/usr/lib" -a "X${exec_prefix}/lib" != "X/usr/lib64"; then
           CURLLIBDIR="-L${exec_prefix}/lib "
        else
           CURLLIBDIR=""
        fi
        if test "Xno" = "Xyes"; then
          echo ${CURLLIBDIR}-lcurl -lidn -lssl -lcrypto -lssl -lcrypto -lldap -lz -lrt
        else
          echo ${CURLLIBDIR}-lcurl
        fi
        ;;

    --static-libs)
        if test "Xyes" != "Xno" ; then
          echo ${exec_prefix}/lib/libcurl.a  -lidn -lssl -lcrypto -lssl -lcrypto -lldap -lz -lrt
        else
          echo "curl was built with static libraries disabled" >&2
          exit 1
        fi
        ;;

    --configure)
        echo " '--prefix=/home/jkeroes'"
        ;;

    *)
        echo "unknown option: $1"
        usage 1
        ;;
    esac
    shift
done

exit 0
