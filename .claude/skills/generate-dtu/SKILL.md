---
name: generate-dtu
description: "Generate Digital Twin mock services for third-party API testing."
allowed-tools: Read, Write, Bash, Glob
argument-hint: "API name (e.g., stripe, auth0, sendgrid)"
---

# Generate Digital Twin

Creates a lightweight mock server that replicates the API contract of a third-party service, based on the API_SPEC.md and existing integration code.

## Process
1. Read docs/API_SPEC.md for external API dependencies
2. For each dependency (or $ARGUMENTS if specified):
   a. Scan codebase for how the API is called (endpoints, params, response shapes)
   b. Generate a mock server in tests/mocks/[service-name]/
   c. Include: all observed endpoints, realistic response data, common error responses
   d. Add a start script to package.json: "mock:[service]"
3. Update TESTING_PLAN.md with DTU usage instructions
4. Generate a docker-compose.test.yml that starts all mocks

## Mock Server Template (Node.js/Express)
Each mock gets:
- Express server on a unique port
- All endpoints the app calls
- Configurable responses (success, error, rate-limit)
- Request logging for verification
- Startup check endpoint: GET /health

## Usage in Tests
Tests import from tests/mocks/config.js which maps service names to localhost URLs.
Set environment variables to point at mocks instead of real APIs.

## Anti-Reward-Hacking via DTU
The implementation agent MUST NOT be able to see or modify DTU validation logic.
This prevents the agent from gaming tests by hardcoding expected responses.

Architecture:
1. DTU mocks live in tests/mocks/ (visible to implementation agent for endpoint discovery)
2. DTU VALIDATION LOGIC lives in .holdouts/ (hidden from implementation, loaded only by holdout-validate agent)
3. Holdout scenarios reference DTU endpoints but the acceptance criteria are opaque to the implementation agent
4. The holdout-validate agent runs in a SEPARATE session that cannot modify source code (read-only + run tests only)

Enforcement in run-pipeline.sh:
- Implementation phases use --permission-mode with a deny list for .holdouts/
- The holdout-validate phase uses --permission-mode that allows read-only on source + execute on tests
- DTU mocks include a tamper-detection header: if an implementation modifies mock responses, the mock logs it and holdout validation fails automatically

Add to each DTU mock server:
```javascript
// Tamper detection: log if anyone modifies responses at runtime
let responseModified = false;
app.use((req, res, next) => {
  if (req.method === 'PUT' || req.method === 'PATCH') {
    if (req.path.startsWith('/mock-config')) {
      responseModified = true;
      console.error('[DTU-TAMPER] Response modification detected');
    }
  }
  next();
});
app.get('/health', (req, res) => {
  res.json({ healthy: true, tampered: responseModified });
});
```
