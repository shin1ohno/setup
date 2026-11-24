# frozen_string_literal: true
#
# openssl@3 — the OpenSSL that rbenv builds Ruby's openssl extension against.
#
# darwin-only (see cookbooks/openssl3/platform): Linux builds Ruby against the
# distro -dev packages and passes no --with-openssl-dir (cookbooks/rbenv).
#
# Why a versioned formula and not the plain `openssl` name: Homebrew's
# `openssl` alias moved to openssl@4 (4.x), so /opt/homebrew/opt/openssl now
# points at OpenSSL 4. Ruby 4.0.5's bundled openssl gem (4.0.0) still reads
# ASN1_BIT_STRING fields directly (ext/openssl/ossl_asn1.c:240), which OpenSSL 4
# made opaque, so `rbenv install 4.0.5` died at `compiling ossl_asn1.c` with
# "incomplete definition of type 'ASN1_BIT_STRING'" (2026-11-24). openssl@3 is
# keg-only, so installing it does not touch the system include path, and
# cookbooks/rbenv points --with-openssl-dir at its keg explicitly.
package "openssl@3"
