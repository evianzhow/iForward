#!/bin/bash
cp /Library/PreferenceLoader/Preferences/iForward.plist /Library/Application\ Support/iForward/iForward_bk.plist
rm /Library/PreferenceLoader/Preferences/iForward.plist
killall SpringBoard
