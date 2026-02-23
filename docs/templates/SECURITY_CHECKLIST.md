# Security Checklist

## Overview
<!-- TODO: Security posture, compliance requirements, threat model summary -->

## Authentication
- [ ] Auth mechanism implemented and tested
- [ ] Passwords hashed with bcrypt/argon2 (cost factor >= 12)
- [ ] JWT tokens have appropriate expiry
- [ ] Refresh token rotation implemented
- [ ] Session invalidation on password change
- [ ] Rate limiting on login endpoint
- [ ] Account lockout after failed attempts

## Authorization
- [ ] Role-based access control (RBAC) implemented
- [ ] Resource-level permission checks on all endpoints
- [ ] No horizontal privilege escalation possible
- [ ] Admin endpoints restricted
- [ ] API key scoping (read/write/admin)

## Input Validation
- [ ] All user input validated and sanitized
- [ ] SQL injection prevention (parameterized queries)
- [ ] XSS prevention (output encoding, CSP headers)
- [ ] Command injection prevention
- [ ] Path traversal prevention
- [ ] File upload validation (type, size, content)

## Data Protection
- [ ] PII encrypted at rest
- [ ] Sensitive data encrypted in transit (TLS 1.2+)
- [ ] No secrets in source code or logs
- [ ] Database credentials rotated
- [ ] Backup encryption enabled

## API Security
- [ ] CORS configured restrictively
- [ ] Rate limiting on all endpoints
- [ ] Request size limits
- [ ] No sensitive data in URL parameters
- [ ] API versioning strategy
- [ ] Webhook signature verification

## Infrastructure
- [ ] Debug mode disabled in production
- [ ] Error messages don't leak internals
- [ ] Security headers set (HSTS, X-Frame-Options, etc.)
- [ ] Dependencies scanned for vulnerabilities
- [ ] Container images scanned

## Logging & Monitoring
- [ ] Authentication events logged
- [ ] Authorization failures logged
- [ ] Sensitive data excluded from logs
- [ ] Log injection prevention
- [ ] Alerting on suspicious patterns

## Compliance
<!-- TODO: List applicable compliance requirements (SOC2, GDPR, HIPAA, etc.) -->
- [ ] Data retention policy implemented
- [ ] User data export capability
- [ ] User data deletion capability
- [ ] Privacy policy updated

## Threat Model
<!-- Key threats identified and mitigations -->

| Threat | Severity | Mitigation | Status |
|--------|----------|------------|--------|
| | | | |
