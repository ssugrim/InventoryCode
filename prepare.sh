    #!/bin/bash
    # Run this before you save the image
    # Root user stuff to clean
    CLEAN_ROOT="/root/.ssh /root/.viminfo /root/.lesshst /root/.bash_history"
    # Tmp stuff to clean
    CLEAN_TMP="/tmp/* /var/tmp/"
    # We do not want documentation on our baselines
    CLEAN_DOC="/usr/doc/* /usr/share/doc/*"
    # Udev data to clean. Udev likes keeps interface names persistent accross bootups. We
    # do not want that behaviour so we remove the saved rules and the generator rules
    CLEAN_UDEV="/etc/udev/rules.d/70-persistent-net.rules"
    # Old logs
    CLEAN_LOGS="/var/log/*"
    # All the data we want to clean
    CLEAN="$CLEAN_TMP $CLEAN_DOC $CLEAN_UDEV $CLEAN_LOGS $CLEAN_ROOT"
    apt-get clean
    apt-get update
    rm -rf $CLEAN
    rm /etc/hostname
    history -c

    echo "Baseline orbit image this image is based on /.orbit_image:"
    cat /.orbit_image

    # Apt likes this dir there, shut it up otherwise it complains
    mkdir /var/log/apt
    poweroff

