# Sieve filter for andrew@csmak.com: one folder per group of role aliases.
# Mail to andrew@ itself stays in Inbox. Envelope matches catch Bcc; headers catch forwarded copies.
# Install: JMAP SieveScript/set (see README). Folders must exist; :create is a safety net.
require ["fileinto", "envelope", "mailbox"];

# Spam first. Stalwart writes X-Spam-Status: No on mail to an alias even at spam scores,
# so the verdict in X-Spam-Score ("spam, score=..." or "ham, score=...") counts too.
if anyof (header :is "X-Spam-Status" "Yes",
          header :matches "X-Spam-Score" "spam,*") {
    fileinto "Junk Mail";
    stop;
}

if anyof (envelope :is "to" ["support@csmak.com", "contact@csmak.com", "info@csmak.com"],
          address :is ["to", "cc"] ["support@csmak.com", "contact@csmak.com", "info@csmak.com"]) {
    fileinto :create "Soporte";
    stop;
}
if anyof (envelope :is "to" "billing@csmak.com",
          address :is ["to", "cc"] "billing@csmak.com") {
    fileinto :create "Facturación";
    stop;
}
if anyof (envelope :is "to" ["legal@csmak.com", "privacy@csmak.com"],
          address :is ["to", "cc"] ["legal@csmak.com", "privacy@csmak.com"]) {
    fileinto :create "Legal";
    stop;
}
if anyof (envelope :is "to" ["abuse@csmak.com", "security@csmak.com"],
          address :is ["to", "cc"] ["abuse@csmak.com", "security@csmak.com"]) {
    fileinto :create "Seguridad";
    stop;
}
# Includes the DMARC and TLS-RPT reports.
if anyof (envelope :is "to" ["postmaster@csmak.com", "hostmaster@csmak.com", "webmaster@csmak.com"],
          address :is ["to", "cc"] ["postmaster@csmak.com", "hostmaster@csmak.com", "webmaster@csmak.com"]) {
    fileinto :create "Sistema";
    stop;
}
