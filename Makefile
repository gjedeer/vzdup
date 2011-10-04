#
# Makefile to generate DEB, RPM and TGZ for vzdup
#
# possible targets:
#
# all:          create DEB, RPM and TGZ packages
# clean:        cleanup
# deb:          create debian package
# rpm:	        create rpm package
# srpm:	        create src.rpm package
# dist:         create tgz package
# install:      install files

VERSION=0.9
PACKAGE=vzdup
PKGREL=1

#ARCH:=$(shell dpkg-architecture -qDEB_BUILD_ARCH)
#RPMARCH:=$(shell rpm --eval %_build_arch)
ARCH=all
RPMARCH=noarch

DESTDIR=
PREFIX=/usr
SBINDIR=${PREFIX}/sbin
MANDIR=${PREFIX}/share/man
PERLLIBDIR=${PREFIX}/share/perl5/PVE
DOCDIR=${PREFIX}/share/doc
MAN1DIR=${MANDIR}/man1/

DEB=${PACKAGE}_${VERSION}-${PKGREL}_${ARCH}.deb
RPM=${PACKAGE}-${VERSION}-${PKGREL}.${RPMARCH}.rpm
SRPM=${PACKAGE}-${VERSION}-${PKGREL}.src.rpm
DISTDIR=$(PACKAGE)-$(VERSION)
TGZ=${DISTDIR}.tar.gz

RPMSRCDIR=$(shell rpm --eval %_sourcedir)
RPMDIR=$(shell rpm --eval %_rpmdir)
SRPMDIR=$(shell rpm --eval %_srcrpmdir)

DISTFILES=			\
	Makefile  		\
	control.in  		\
	vzdup.spec.in		\
	copyright  		\
	VZDup.pm 		\
	vzduprestore 		\
	vzdup

PKGSOURCE= 			\
	vzduprestore		\
	vzduprestore.1.gz	\
	vzdup 			\
	vzdup.1.gz 		\
	VZDup.pm 		\
	control

all: ${TGZ} ${DEB} ${RPM}

control: control.in
	sed -e s/@@ARCH@@/${ARCH}/ -e s/@@VERSION@@/${VERSION}/ -e s/@@PKGRELEASE@@/${PKGREL}/ <$< >$@

vzdup.spec: vzdup.spec.in
	sed -e s/@@ARCH@@/${ARCH}/ -e s/@@VERSION@@/${VERSION}/ -e s/@@PKGRELEASE@@/${PKGREL}/ <$< >$@

.PHONY: install
install: ${PKGSOURCE}
	install -d ${DESTDIR}${SBINDIR}
	install -m 0755 vzdup ${DESTDIR}${SBINDIR}
	install -m 0755 vzduprestore ${DESTDIR}${SBINDIR}
	install -d ${DESTDIR}${MAN1DIR}
	install -m 0644 vzdup.1.gz ${DESTDIR}${MAN1DIR}
	install -m 0644 vzduprestore.1.gz ${DESTDIR}${MAN1DIR}
	install -d ${DESTDIR}${PERLLIBDIR}
	install -m 0644 VZDup.pm ${DESTDIR}${PERLLIBDIR}
	install -d ${DESTDIR}${PERLLIBDIR}/VZDup


.PHONY: deb
deb ${DEB}: ${PKGSOURCE} ${DISTFILES}
	rm -rf debian
	mkdir debian
	make DESTDIR=debian install
	install -d -m 0755 debian/DEBIAN
	install -m 0644 control debian/DEBIAN
	install -D -m 0644 copyright debian/${DOCDIR}/${PACKAGE}/copyright
	dpkg-deb --build debian	
	mv debian.deb ${DEB}
	rm -rf debian
	lintian ${DEB}

%.1.gz: %
	rm -f $*.1.gz
	pod2man -n $* -s 1 -r ${VERSION} -c "Proxmox Documentation"  <$* |gzip -c9 >$*.1.gz

.PHONY: rpm
rpm ${RPM}: ${TGZ} ${PACKAGE}.spec
	cp ${TGZ} ${RPMSRCDIR}
	rpmbuild -bb --nodeps --clean --rmsource ${PACKAGE}.spec
	mv ${RPMDIR}/${RPMARCH}/${RPM} ${RPM} 

.PHONY: srpm
srpm ${SRPM}: ${TGZ} ${PACKAGE}.spec
	cp ${TGZ} ${RPMSRCDIR}
	rpmbuild -bs --nodeps --rmsource ${PACKAGE}.spec
	mv ${SRPMDIR}/${SRPM} ${SRPM} 


.PHONY: dist
dist: ${TGZ}

${TGZ}: ${DISTFILES}
	make clean
	rm -rf ${TGZ} ${DISTDIR}
	mkdir ${DISTDIR}
	cp ${DISTFILES} ${DISTDIR}
	tar czvf ${TGZ} ${DISTDIR}
	rm -rf ${DISTDIR} 

.PHONY: clean
clean: 	
	rm -rf debian *~ *.deb *.tar.gz *.rpm *.1.gz vzdup.spec control ${DISTDIR}
