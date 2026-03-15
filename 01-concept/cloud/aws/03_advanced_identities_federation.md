# Advanced Permissions & Accounts

## 1. SAML2.0 Identity Federation
SAML ***(Security Assertion Markup Language)*** is an XML-based open standard for exchanging authentication and authorization data between parties, particularly between an identity provider (IdP) and a service provider (SP).

- Open standard used by many Idp's
- Indirectly use on-premises IDs with AWS (Console & CLI)
    - It exchanges AWS creds against on-premises IDs or creds.
- Enterprise Identity Provider ... SAML 2.0 Compatible and not Google based.
- Uses IAM Roles & AWS Temporary Creds __(12 hour validity)__

![SAML](../../../Images/SAML.png)