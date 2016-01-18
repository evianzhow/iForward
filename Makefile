XCODE_BASE=/Applications/Xcode.app/Contents
#SIMULATOR_BASE=$(XCODE_BASE)/Developer/Platforms/iPhoneSimulator.platform
SIMULATOR_BASE=$(XCODE_BASE)/Developer/Platforms/iPhoneOS.platform
FRAMEWORKS=$(SIMULATOR_BASE)/Developer/SDKs/iPhoneOS6.1.sdk/System/Library/Frameworks/
INCLUDES=$(SIMULATOR_BASE)/Developer/SDKs/iPhoneOS6.1.sdk/usr/include

IPHONE_IP:=
PROJECTNAME:=iForward
APPFOLDER:=$(PROJECTNAME).app
INSTALLFOLDER:=$(PROJECTNAME).app

CC:=clang
CPP:=clang++

#CFLAGS += -objc-arc
#CFLAGS += -fblocks
#CFLAGS += -g0 -O2
CFLAGS += -I"$(SRCDIR)"

#CPPFLAGS += -objc-arc
#CPPFLAGS += -fblocks
#CPPFLAGS += -g0 -O2
CPPLAGS += -I"$(SRCDIR)"

#CFLAGS += -F"/usr/share/iPhoneOS6.0.sdk/System/Library/Frameworks"
CFLAGS += -F"$(SIMULATOR_BASE)/Developer/SDKs/iPhoneOS6.1.sdk/System/Library/PrivateFrameworks/" 

CFLAGS += -arch armv7s
#CFLAGS += -arch x86_64
#CFLAGS += -mios-simulator-version-min=6.1
#CFLAGS += -fobjc-abi-version=2
CFLAGS += -isysroot /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS6.1.sdk
LDFLAGS += -framework Foundation 
LDFLAGS += -framework UIKit 
LDFLAGS += -framework CoreGraphics
//LDFLAGS += -framework AVFoundation
LDFLAGS += -framework AddressBook
//LDFLAGS += -framework AddressBookUI
//LDFLAGS += -framework AudioToolbox
//LDFLAGS += -framework AudioUnit
//LDFLAGS += -framework CFNetwork
//LDFLAGS += -framework CoreAudio
LDFLAGS += -framework CoreData
LDFLAGS += -framework CoreFoundation
//LDFLAGS += -framework GraphicsServices
//LDFLAGS += -framework CoreLocation
//LDFLAGS += -framework ExternalAccessory
//LDFLAGS += -framework GameKit
//LDFLAGS += -framework IOKit
//LDFLAGS += -framework MapKit
//LDFLAGS += -framework MediaPlayer
//LDFLAGS += -framework MessageUI
//LDFLAGS += -framework MobileCoreServices
//LDFLAGS += -framework OpenAL
//LDFLAGS += -framework OpenGLES
LDFLAGS += -framework QuartzCore
//LDFLAGS += -framework Security
//LDFLAGS += -framework StoreKit
//LDFLAGS += -framework System
//LDFLAGS += -framework SystemConfiguration
//LDFLAGS += -framework CoreSurface
LDFLAGS += -framework GraphicsServices
//LDFLAGS += -framework Celestial
//LDFLAGS += -framework WebCore
//LDFLAGS += -framework WebKit
//LDFLAGS += -framework SpringBoardUI
//LDFLAGS += -framework TelephonyUI
//LDFLAGS += -framework JavaScriptCore
//LDFLAGS += -framework PhotoLibrary
LDFLAGS += -L"/usr/local/iForward/lib"
LDFLAGS += -lcurl
#LDFLAGS += -L"/usr/lib" -lssl -lcrypto

SRCDIR=Classes
OBJS+=$(patsubst %.m,%.o,$(wildcard $(SRCDIR)/*.m))
OBJS+=$(patsubst %.c,%.o,$(wildcard $(SRCDIR)/*.c))
OBJS+=$(patsubst %.cpp,%.o,$(wildcard $(SRCDIR)/*.cpp))

INFOPLIST:=$(wildcard *Info.plist)

RESOURCES+=$(wildcard ./Images/*)
RESOURCES+=$(wildcard ./Resources/*)
RESOURCES+=$(wildcard ./Localizations/*)


all:	$(PROJECTNAME)

$(PROJECTNAME):	$(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) $(filter %.o,$^) -o $@ 

%.o:	%.m
	$(CC) -c $(CFLAGS) $< -o $@

%.o:	%.c
	$(CC) -c $(CFLAGS) $< -o $@

%.o:	%.cpp
	$(CPP) -c $(CPPFLAGS) $< -o $@


dist:	$(PROJECTNAME)
	cp iForward cydia/iForward/usr/bin/iForward
	dpkg-deb -b cydia/iForward

langs:
	ios-genLocalization

install: dist
ifeq ($(IPHONE_IP),)
	echo "Please set IPHONE_IP"
else
	ssh root@$(IPHONE_IP) 'dpkg -r iForward'
	scp cydia/iForward.deb root@$(IPHONE_IP):iForward.deb
	ssh root@$(IPHONE_IP) 'dpkg -i iForward'
	echo "Application installed"
endif

uninstall:
ifeq ($(IPHONE_IP),)
	echo "Please set IPHONE_IP"
else
	ssh root@$(IPHONE_IP) 'dpkg -r iForward'
	echo "Application uninstalled"
endif
clean:
	find . -name \*.o|xargs rm -rf
	rm -rf $(APPFOLDER)
	rm -f $(PROJECTNAME)

.PHONY: all dist install uninstall clean