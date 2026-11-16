#!/usr/bin/env python3
"""Render the Stalwart plan (NDJSON) for the csmak.com pilot. Idempotent: upserts + singleton updates.

Usage: ./plan.py | ./scli apply --stdin
       ./plan.py cottonstream | ./scli apply --stdin   (only the cottonstream.es objects; safe while andrew.pass is empty)
Secrets are not in the plan: Cloudflare and Resend keys are read by Stalwart from its environment
(secrets/stalwart.env); account passwords are read from secrets/*.pass when rendering.
"""
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
DOMAIN = "csmak.com"
HOSTNAME = "mail.csmak.com"
# Role addresses delivered to andrew: contact/support/info for people, the rest per RFC 2142 and common practice
# (postmaster, abuse and the DMARC/TLS-RPT reports; security for security.txt; privacy for GDPR requests).
ANDREW_ALIASES = ("contact", "postmaster", "abuse", "support", "info", "security", "privacy", "billing", "legal",
                  "hostmaster", "webmaster")
# Second domain. Same server, its own Resend account so limits and reputation
# don't mix with csmak.com; mail it sends leaves through the relay chosen by sender domain (MtaOutboundStrategy).
COTTON = "cottonstream.es"
# Technical addresses of cottonstream.es (DMARC/TLS-RPT reports, RFC 2142) reach andrew, not the people who use it.
COTTON_ANDREW_ALIASES = ("postmaster", "abuse", "hostmaster", "webmaster")
# Connections arrive through edge-tunnel (masqueraded) with a PROXY v2 header from HAProxy on the VPS.
PROXY = "10.203.66.2/32"


def secret(name: str) -> str:
    return (HERE / "secrets" / f"{name}.pass").read_text().strip()


def upsert(obj: str, key: str, value: dict, match=("name",)) -> dict:
    return {"@type": "upsert", "object": obj, "matchOn": list(match), "value": {key: value}}


def update(obj: str, value: dict) -> dict:
    return {"@type": "update", "object": obj, "value": value}


def setof(*items) -> dict:
    return {i: True for i in items}


def listof(*items) -> dict:
    return {str(n): i for n, i in enumerate(items)}


def listener(name: str, protocol: str, port: int, implicit_tls: bool = False) -> dict:
    return upsert("NetworkListener", f"l-{name}", {
        "name": name, "protocol": protocol, "bind": setof(f"0.0.0.0:{port}"), "implicitTls": implicit_tls,
    })


plan = [
    upsert("DnsServer", "cf", {
        "@type": "Cloudflare", "description": "Cloudflare (csmak.com)",
        "secret": {"@type": "EnvironmentVariable", "variableName": "CLOUDFLARE_DNS_TOKEN"},
    }, match=("description",)),
    upsert("AcmeProvider", "le", {
        "description": "Let's Encrypt", "challengeType": "Dns01", "contact": setof(f"postmaster@{DOMAIN}"),
    }, match=("description",)),
    upsert("Domain", "dom", {
        "name": DOMAIN,
        "certificateManagement": {"@type": "Automatic", "acmeProviderId": "#le", "subjectAlternativeNames": setof("mail")},
        "dkimManagement": {"@type": "Automatic"},
        # SPF and DMARC are kept by hand (SPF must authorise Resend, not this host); no MTA-STS/autoconfig
        # until HTTPS for mail.csmak.com is published. SRV records are kept by hand (only IMAPS 993 and
        # submissions 465 are exposed), since automatic SRV would also advertise POP3, JMAP and DAV.
        "dnsManagement": {"@type": "Automatic", "dnsServerId": "#cf",
                          "publishRecords": {"dkim": True, "mx": True, "tlsRpt": True}},
        "subAddressing": {"@type": "Enabled"},
    }),
    update("SystemSettings", {
        "defaultHostname": HOSTNAME, "defaultDomainId": "#dom", "proxyTrustedNetworks": setof(PROXY),
        "mailExchangers": listof({"hostname": HOSTNAME, "priority": 10}),
    }),
    listener("smtp", "smtp", 25),
    listener("submissions", "smtp", 465, implicit_tls=True),
    listener("submission", "smtp", 587),
    listener("imaps", "imap", 993, implicit_tls=True),
    # Plain HTTP: host loopback (admin, compose.yaml) and Caddy (https://mail.csmak.com, JMAP for Bulwark; /admin
    # blocked there). Caddy sets X-Forwarded-For to exactly one entry: the browser, or what Bulwark forwarded.
    listener("http", "http", 8080),
    update("Http", {
        "clientIpSource": "xForwardedFor", "forwardedHops": 1,
        # Bulwark (webmail.csmak.com) calls JMAP from the browser; auth is a bearer token, no cookies.
        "usePermissiveCors": True, "enableHsts": True,
    }),
    # Every remote recipient goes through Resend, reached via the VPS (see compose.yaml extra_hosts).
    upsert("MtaRoute", "resend", {
        "@type": "Relay", "name": "resend", "description": "Resend via vps-proxy",
        "host": "smtp.resend.com", "port": 2465, "implicitTls": True, "protocol": "smtp",
        "authUsername": "resend",
        "authSecret": {"@type": "EnvironmentVariable", "variableName": "RESEND_SMTP_KEY"},
    }),
    update("MtaOutboundStrategy", {
        "route": {"match": listof({"if": "is_local_domain(rcpt_domain)", "then": "'local'"},
                                  {"if": f"sender_domain == '{COTTON}'", "then": "'resend-cottonstream'"}),
                  "else": "'resend'"},
    }),
    upsert("Account", "admin", {
        "@type": "User", "name": "admin", "domainId": "#dom", "roles": {"@type": "Admin"},
        "credentials": listof({"@type": "Password", "secret": secret("admin")}),
        "description": "Server administrator (no mail use)",
    }),
    upsert("Account", "andrew", {
        "@type": "User", "name": "andrew", "domainId": "#dom", "roles": {"@type": "User"},
        "credentials": listof({"@type": "Password", "secret": secret("andrew")}),
        "aliases": listof(*({"name": n, "domainId": "#dom"} for n in ANDREW_ALIASES),
                          *({"name": n, "domainId": "#cs"} for n in COTTON_ANDREW_ALIASES)),
    }),
    # Automated mail from apps (SMTP 465 at mail.csmak.com). Nobody reads its inbox: apps should set
    # Reply-To: support@csmak.com.
    upsert("Account", "noreply", {
        "@type": "User", "name": "no-reply", "domainId": "#dom", "roles": {"@type": "User"},
        "credentials": listof({"@type": "Password", "secret": secret("no-reply")}),
        "description": "Envío automático de aplicaciones",
        "aliases": listof({"name": "notifications", "domainId": "#dom"}),
    }),
]

cotton = [
    upsert("Domain", "cs", {
        "name": COTTON,
        "certificateManagement": {"@type": "Automatic", "acmeProviderId": "#le", "subjectAlternativeNames": setof("mail")},
        "dkimManagement": {"@type": "Automatic"},
        # MX is kept by hand (mail.cottonstream.es): mailExchangers is global and would publish mail.csmak.com.
        # SPF, DMARC, SRV and the Resend records too, as for csmak.com.
        "dnsManagement": {"@type": "Automatic", "dnsServerId": "#cf",
                          "publishRecords": {"dkim": True, "tlsRpt": True}},
        "subAddressing": {"@type": "Enabled"},
    }),
    upsert("MtaRoute", "resendcs", {
        "@type": "Relay", "name": "resend-cottonstream", "description": f"Resend ({COTTON}) via vps-proxy",
        "host": "smtp.resend.com", "port": 2465, "implicitTls": True, "protocol": "smtp",
        "authUsername": "resend",
        "authSecret": {"@type": "EnvironmentVariable", "variableName": "RESEND_SMTP_KEY_COTTONSTREAM"},
    }),
]
# The strategy names the route, so it goes after it; "cf" and "le" already exist, referenced by name.
if sys.argv[1:] == ["cottonstream"]:
    plan = [op for op in plan if op["object"] in ("DnsServer", "AcmeProvider")] + cotton + \
           [op for op in plan if op["object"] == "MtaOutboundStrategy"]
else:
    plan = plan[:3] + cotton[:1] + plan[3:] + cotton[1:]
    i = next(n for n, op in enumerate(plan) if op["object"] == "MtaOutboundStrategy")
    plan.append(plan.pop(i))

for op in plan:
    print(json.dumps(op))
