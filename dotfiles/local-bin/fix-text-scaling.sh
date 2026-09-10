#!/bin/bash
# Set GTK text-scaling-factor appropriate for the current desktop session.
# KDE manages HiDPI for GTK apps via this setting; COSMIC handles scaling at
# the compositor level so this should stay at 1.0.

case "$XDG_CURRENT_DESKTOP" in
    KDE)
        gsettings set org.gnome.desktop.interface text-scaling-factor 1.75
        ;;
    COSMIC)
        gsettings set org.gnome.desktop.interface text-scaling-factor 1.0
        ;;
esac
