# Common Library Update Workflow

## IMPORTANT: Git Tag Requirement

**When any changes are made to `extend-challenge-common/` module:**

⚠️ **YOU MUST NOTIFY THE USER to build and publish a new Git tag**

### Reason
The services (`extend-challenge-service` and `extend-challenge-event-handler`) use the common module as a **GitHub-published dependency**, not a local module.

### Workflow

1. **After making changes to `extend-challenge-common/`:**
   - Commit all changes
   - **STOP and notify user:** "Changes made to extend-challenge-common. You need to create and push a new Git tag."

2. **User will execute:**
   ```bash
   cd extend-challenge-common
   git add .
   git commit -m "Description of changes"
   git tag v0.x.x  # Increment version
   git push origin main
   git push origin v0.x.x
   ```

3. **Then update services:**
   ```bash
   # In extend-challenge-service and extend-challenge-event-handler
   go get github.com/AccelByte/extend-challenge-common@v0.x.x
   go mod tidy
   ```

4. **Rebuild services:**
   ```bash
   cd extend-challenge-event-handler
   go build -o event-handler .
   
   cd extend-challenge-service
   go build -o service .
   ```

### Phase 2 Changes Requiring Tag

**Files modified in extend-challenge-common:**
- `pkg/repository/postgres_goal_repository.go` - Added `BatchUpsertProgressWithCOPY()`
- `pkg/repository/goal_repository.go` - Added interface method

**Action needed:** User must create and push new tag (e.g., `v0.2.0`) before services can use the new COPY method.

### Detection Pattern

If you modify any file in:
- `extend-challenge-common/pkg/**/*.go`
- `extend-challenge-common/go.mod`

→ Remind user to publish new tag

### Example Notification

```
✅ Phase 2 implementation complete in extend-challenge-common.

⚠️  IMPORTANT: You need to publish a new Git tag before the services can use the new COPY method:

1. Tag and push extend-challenge-common:
   cd extend-challenge-common
   git tag v0.2.0
   git push origin main
   git push origin v0.2.0

2. Update services to use new tag:
   cd ../extend-challenge-event-handler
   go get github.com/AccelByte/extend-challenge-common@v0.2.0
   go mod tidy
   go build -o event-handler .
```
