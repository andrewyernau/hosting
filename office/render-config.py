#!/usr/bin/env python3
"""Patch the image's default coolwsd.xml (stdin) into ours (stdout). Run via ./office.sh config."""
import re, sys

WOPI_HOSTS = ["https://webmail.csmak.com:443", "https://webmail.cottonstream.es:443"]
xml = sys.stdin.read()

def sub(pattern, repl, count=1):
    global xml
    xml, n = re.subn(pattern, repl, xml, count=count, flags=re.S)
    if n != count:
        sys.exit(f"pattern not found: {pattern}")

# TLS ends in Caddy; coolwsd speaks plain HTTP on selfhost_proxy but builds https:// URLs.
sub(r'(<ssl desc="SSL settings">\s*(?:<!--.*?-->\s*)?<enable [^>]*>)true(</enable>)', r'\1false\2')
sub(r'(<termination [^>]*>)false(</termination>)', r'\1true\2')
# Only the two Bulwark instances may act as WOPI hosts.
groups = "".join(f'\n            <group><host allow="true">{h}</host></group>' for h in WOPI_HOSTS)
sub(r'(<alias_groups [^>]*mode=)"first">(.*?)(\s*</alias_groups>)', r'\1"groups">' + groups.replace("\\", r"\\") + r'\3')
# REST/POST (convert-to etc.) only from inside the container; no extra data sources from post_allow.
sub(r'<post_allow ([^>]*)allow="true">.*?</post_allow>',
    r'<post_allow \1allow="false">\n        <host>127.0.0.1/32</host>\n        <host>::1/128</host>\n      </post_allow>')
# Documents may not pull data (WEBSERVICE, linked images...) from the LAN or Docker networks: only WOPI hosts.
sub(r'(<lok_allow [^>]*>).*?(</lok_allow>)', r'\1\2')
sub(r'(<admin_console [^>]*>\s*<enable [^>]*>)true(</enable>)', r'\1false\2')
sub(r'(<allowed_languages [^>]*>)[^<]*(</allowed_languages>)', r'\1es_ES en_GB en_US ru\2')
# Bind-mounting jails needs CAP_SYS_ADMIN, which we don't grant: copy instead (startup a bit slower, no error spam).
sub(r'(<mount_jail_tree [^>]*>)true(</mount_jail_tree>)', r'\1false\2')
sys.stdout.write(xml)
