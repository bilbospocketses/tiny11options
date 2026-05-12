# Release signing setup — step by step

This is the verbose walkthrough for wiring Microsoft Trusted Signing (a.k.a. Artifact Signing) into the GitHub Actions release workflow. Follow this once; after it's done, every `v*` tag push produces signed binaries automatically.

> **Naming note (2025 rebrand):** Microsoft renamed **Trusted Signing** to **Artifact Signing** in their Azure Portal UI in 2025. The GitHub Action is still published at `azure/trusted-signing-action` and our `release.yml` references that name. **Azure Portal screens say "Artifact Signing"; the GitHub Action and our secret names say "Trusted Signing".** Both refer to the same service. Don't worry about the inconsistency.

---

## What you need before starting

- An **Artifact Signing account** in your Azure subscription (~$10/mo)
- A **completed identity validation** under that account (Part 0 below)
- A **certificate profile** built on top of that identity (Part 0 below)
- Admin access to your `bilbospocketses/tiny11options` GitHub repo (Settings access)
- A web browser and a few hours total (most of it waiting on identity validation)

**Realistic timeline:**

| Phase | Wall-clock |
|---|---|
| Part 0 — submit identity validation request | ~10 min |
| Part 0 — wait for Microsoft to complete validation | **Same day to 20 business days** (Individual Developer via Au10TIX is usually fast; Organization validation is slower) |
| Part 0 — create certificate profile after validation completes | ~5 min |
| Parts 1-5 — wire Azure + GitHub | ~30-45 min |
| Total active work | ~45-60 min |
| Total with validation wait | **up to several weeks if Organization validation hits a documentation back-and-forth** |

Start Part 0 NOW so the validation clock runs while you're doing other work.

---

## Part 0 — Identity validation + certificate profile

You can't sign code until Microsoft validates the publisher identity that will appear on the certificate. Two flavors of validation; pick one.

### 0a. Choose your identity type

| Type | Cert subject says | Validation method | Time | When to use |
|---|---|---|---|---|
| **Individual Developer** | Your legal name + city/state | Au10TIX QR-code flow with government ID | Same day to a few days | Shipping under your personal name (most indie tools — recommended for tiny11options) |
| **Organization** | Legal business entity name | Microsoft manual review of business registration docs | 1-20 business days, sometimes longer if docs need follow-up | Shipping under a registered business (BoxTechs etc.) |
| **Private Trust** | Anything | Internal | Instant | DON'T use — private-trust certs aren't recognized outside your own Active Directory; useless for public distribution |

**Recommendation for tiny11options:** Individual Developer. Faster, simpler, and "Jamie Chapman" on the certificate is fine for an indie tool. If you later want to ship under a business name, you can add an Organization identity validation alongside the existing Individual one without losing the existing certificate.

### 0b. Individual Developer flow (recommended)

**Prereqs:**
- Government-issued photo ID (passport, driver's license, or state ID)
- A mobile device with camera (iPhone or Android, recent OS)
- Microsoft Authenticator app installed on your phone
- A few uninterrupted minutes once you start (the verification session times out)

**Steps:**

1. Sign in to <https://portal.azure.com>.
2. Top search bar: type **`Artifact Signing`** → click **"Artifact Signing Accounts"** → click your account.
3. In the account's left menu, under **Objects**, click **"Identity validations"**.
4. Click **"+ New identity"** at the top. **Important Microsoft Entra role check:** if the button is grayed out, you don't have the `Artifact Signing Identity Verifier` role on this account. Fix in Access control (IAM) → Add role assignment → assign that role to yourself, then refresh.
5. In the "New identity validation" panel:
   - At the top there's a dropdown that defaults to **"Organization"** — change it to **"Individual"**.
   - Then click **"Public"** (NOT Private — see table above for why).
6. Fill in:
   - **First Name** — exactly as it appears on your government ID. If your ID says "Jamie A. Chapman", enter `Jamie A.` (no special punctuation tricks; match it character-for-character).
   - **Last Name** — same.
   - **Primary Email** — the email Microsoft will send the verification link to. It must be one you control AND will use to sign in to Microsoft Authenticator later in this flow.
   - **Street, City, Country/Region, State/Province, Postal code** — must match your government ID OR a recent utility bill / bank statement that has your name on it.
7. Click **"Certificate subject preview"** at the bottom — preview shows what'll appear on the cert: `CN=Jamie Chapman, L=YourCity, S=YourState, C=US` (or similar). Your email and street address are NOT included.
8. Click **"Create"**.

**Status will change to "In Progress" immediately.** Wait a few seconds and refresh.

9. When status changes to **"Action Required"**: click your name in the list → a side panel opens → click the link under "Please complete your verification here".
10. New browser tab opens at a Microsoft-hosted page. Sign in with the SAME email you used in step 6 (this is critical — the verification flow ties the signed-in MS account to the validation request).
11. Click **"Get verified here through our trusted ID-verifiers"**.
12. You're redirected to **AU10TIX** (Microsoft's identity verification partner). Click **"Let's Begin"**.
13. Enter the primary email from step 6. Au10TIX sends you a PIN by email. Enter the PIN to verify the email.
14. Enter your phone number. Click **"Start"**.
15. **Use your phone's camera to scan the QR code** that appears in the browser. DON'T close the browser tab.
16. On your phone: select **Start** in the Au10TIX flow that opened from the QR scan. Follow the prompts to:
    - Take a photo of the FRONT of your government ID (good lighting, flat surface, no flash, no crop)
    - Take a photo of the BACK of the same ID
    - Take a selfie (matches against the ID photo)
17. After mobile flow completes, your phone shows a "Verifiable Credential" prompt → select **"Open Authenticator"** → in Microsoft Authenticator, tap **"Add"** to add the Verified Credential.
18. Back on the browser (the one with the QR code), it now says **"Present your Verified ID"** with a new QR code. Scan THAT one with your phone. In Authenticator, select **Verifiable Credential** → tap **"Share"**.
19. Browser shows **"Verification Successful"**. Close that browser tab.
20. Back in the Azure Portal Identity validations list, wait a couple minutes and refresh. Status changes from **"Action Required"** to **"In Progress"** to **"Completed"**.

If validation **fails** (status becomes "Failed"), you have to submit a new request. Common causes: ID photo cropped or blurry, name mismatch between request and ID, address doesn't match a supporting document.

### 0c. Organization flow (only if NOT going Individual)

If you want the certificate to say "BoxTechs" instead of "Jamie Chapman", use this flow. Skip if you went Individual in 0b.

1. Azure Portal → Artifact Signing Accounts → your account → Identity validations → **"+ New identity"** → leave dropdown on **"Organization"** → click **"Public"**.
2. Fill in:
   - **Organization Name** — legal business entity exactly as registered (no abbreviations, include "LLC" / "Inc." if applicable)
   - **Website URL** — business website (must match the entity)
   - **Primary Email** — must be on the business's domain (e.g. `you@boxtechs.com`, not Gmail)
   - **Secondary Email** — different from primary, same business domain
   - **Business Identifier** — your DUNS number, state registration number, or equivalent
   - **Street / City / Country / State / Postal** — registered business address
   - **First / Last Name** — YOUR name as the human submitter (you'll do the Individual flow on top of the Organization request)
3. Click **"Create"**.
4. Same as 0b from step 9 onward — you (the human submitter) do the Au10TIX identity verification on top of the Organization request.
5. **In parallel**, Microsoft does manual review of the business registration. If they need more docs (articles of incorporation, business registration certificate, domain ownership proof, etc.), you'll get email + "Action Required" status. **Three upload attempts max.** Documents must be:
   - Issued within the previous 12 months
   - Expiration date at least 2 months in the future (if applicable)
   - Show business name + address matching what you entered in step 2

**Total time:** 1-20 business days, occasionally longer. Don't start this less than 3 weeks before you need to release.

### 0d. Create the certificate profile (after validation completes)

You can ONLY do this once identity validation status is **"Completed"**.

1. Artifact Signing Account → left menu under **Objects** → **"Certificate profiles"**.
2. Click **"+ Create"** at the top, then select a profile type from the dropdown:
   - **"Public Trust"** — pick this. Matches your Public identity validation. Cert is recognized by Windows SmartScreen.
   - Public Trust Test — test/dev only
   - VBS Enclave — only if you're signing Virtualization-Based Security enclave code (not us)
   - Private Trust — useless for public distribution, see 0a
3. Fill in:
   - **Certificate Profile Name:** something like `tiny11options-publisher` (alphanumeric, 5-100 chars, no consecutive hyphens, unique within the account)
   - **Verified CN and O:** dropdown — select the identity validation you completed in 0b or 0c
   - Optional checkboxes for **"Include street address"** and **"Include postal code"** in the cert subject — leave UNCHECKED unless you have a reason (most indie tools don't include street address on the cert)
4. **Certificate Subject Preview** at the bottom shows what the cert will look like — verify it matches expectations.
5. Click **"Create"**.

**The profile name you entered is your `TRUSTED_SIGNING_CERT_PROFILE` secret value.** Save it.

### Checkpoint for Part 0

You should now have:
- ✅ Identity validation status: **Completed**
- ✅ Certificate profile created with a name you've saved
- ✅ Artifact Signing endpoint, account name, and cert profile name all noted for use in Part 1

If any of those isn't true, stop here. **Do not proceed to Part 1 until Part 0 is complete** — the Part 1 steps assume the cert profile already exists and will fail without it.

---

## Part 1 — Collect 3 of the 5 secret values

You can fill in 3 of the 5 GitHub secrets straight from your existing Azure resources. Let's get those first.

### 1a. Find your Artifact Signing endpoint URL

1. Open <https://portal.azure.com> in a browser, sign in.
2. In the top search bar, type **`Artifact Signing`** and click the result labeled **"Artifact Signing Accounts"** under Services.
3. You should see your existing Artifact Signing account listed. Click on it.
4. You're now on the account's **Overview** blade. Look at the right side panel for **"Endpoint"** (or **"Endpoint URI"**). It will look like:

   ```
   https://eus.codesigning.azure.net
   ```

   (The `eus` part is the region code — `eus` = East US, `weu` = West Europe, etc. Yours may be different.)

5. **Copy this entire URL including `https://`.** This is your `TRUSTED_SIGNING_ENDPOINT` secret value. Save it somewhere temporary (notepad, sticky note).

### 1b. Find your Artifact Signing account name

You're already on the Overview blade.

1. At the top of the blade, you'll see breadcrumbs like `Home > Artifact Signing Accounts > YourAccountName`. Or look at the page title.
2. The string after the last `>` is your account name. It's also shown in the Essentials section as **"Name"**.
3. **Copy that name** (it's a short string like `tiny11signing` or whatever you named it). This is your `TRUSTED_SIGNING_ACCOUNT` secret value.

### 1c. Find your certificate profile name

1. Still inside the Artifact Signing account, look at the **left-hand resource menu**. Click **"Certificate profiles"** (under the "Objects" section).
2. You'll see a list of certificate profiles. Click on the one you want to use for signing tiny11options releases (you probably have just one).
3. The profile's **Name** is at the top. **Copy it.** This is your `TRUSTED_SIGNING_CERT_PROFILE` secret value.

### Checkpoint

You should now have 3 of 5 values written down somewhere:

| Secret | Example value |
|---|---|
| `TRUSTED_SIGNING_ENDPOINT` | `https://eus.codesigning.azure.net` |
| `TRUSTED_SIGNING_ACCOUNT` | `tiny11signing` |
| `TRUSTED_SIGNING_CERT_PROFILE` | `tiny11-publisher` |

The remaining 2 (`AZURE_TENANT_ID` and `AZURE_CLIENT_ID`) come from creating the App Registration in Part 2.

---

## Part 2 — Create the App Registration with OIDC federation

This is the GitHub Actions → Azure bridge. GitHub will get a short-lived token (no secrets needed) by proving it's running the workflow in YOUR specific repository on YOUR specific tag.

### 2a. Create the App Registration

1. In the Azure Portal top search bar, type **`Microsoft Entra ID`** and click that result.
2. In Microsoft Entra ID's left menu, click **"App registrations"** (or "Manage" → "App registrations" depending on your portal layout).
3. Click **"+ New registration"** at the top.
4. Fill in:
   - **Name:** `tiny11options-github-signer` (or any name you'll recognize later)
   - **Supported account types:** Select **"Accounts in this organizational directory only (... - Single tenant)"** — this is the most restrictive option, which is what we want.
   - **Redirect URI:** Leave blank (we don't need one for GitHub Actions OIDC).
5. Click **"Register"** at the bottom.

You're now on the new App Registration's **Overview** blade.

### 2b. Grab your two GUIDs

You're on the App Registration's Overview blade. Look at the **Essentials** section near the top:

- **Application (client) ID:** a GUID like `12345678-90ab-cdef-1234-567890abcdef`. **Copy it.** This is your `AZURE_CLIENT_ID` secret value.
- **Directory (tenant) ID:** another GUID below it. **Copy it.** This is your `AZURE_TENANT_ID` secret value.

### Checkpoint

You now have all 5 values:

| Secret | What |
|---|---|
| `AZURE_TENANT_ID` | Directory (tenant) ID from the App Registration |
| `AZURE_CLIENT_ID` | Application (client) ID from the App Registration |
| `TRUSTED_SIGNING_ENDPOINT` | Endpoint URL from the Artifact Signing account |
| `TRUSTED_SIGNING_ACCOUNT` | Artifact Signing account name |
| `TRUSTED_SIGNING_CERT_PROFILE` | Certificate profile name |

Don't add them to GitHub yet — we need to finish wiring Azure first.

### 2c. Add the federated credential

This tells Azure: "trust GitHub Actions when it's pushing a `v*` tag in the `bilbospocketses/tiny11options` repo."

1. Still on your App Registration's blade, in the left menu click **"Certificates & secrets"**.
2. Click the **"Federated credentials"** tab at the top (next to "Client secrets" and "Certificates").
3. Click **"+ Add credential"**.
4. **Federated credential scenario:** select **"GitHub Actions deploying Azure resources"** from the dropdown.
5. Fill in the fields that appear:
   - **Organization:** `bilbospocketses`
   - **Repository:** `tiny11options`
   - **Entity type:** Select **"Tag"** from the dropdown. (NOT "Branch", NOT "Environment", NOT "Pull request".)
   - **GitHub tag name:** `v*`
     - The wildcard `*` matches any tag starting with `v` (so `v1.0.0`, `v1.0.1`, `v2.0`, etc.). Azure will accept `v*` here.
   - **Name:** `github-tag-push` (or any name you'll recognize — this is just a label for you)
   - **Description:** optional, you can leave it blank
6. **Audience** — leave at the default `api://AzureADTokenExchange`. This is the GitHub Actions standard audience for Azure OIDC.
7. **Issuer** — leave at the default `https://token.actions.githubusercontent.com`. Also GitHub Actions standard.
8. Click **"Add"** at the bottom.

### Checkpoint

You should now see one federated credential listed with:
- **Subject identifier:** something like `repo:bilbospocketses/tiny11options:ref:refs/tags/v*`
- **Issuer:** `https://token.actions.githubusercontent.com`

If the Subject doesn't include `refs/tags/v*`, click the credential and edit it — the entity type may have defaulted to Branch instead of Tag.

---

## Part 3 — Grant the App Registration the signing role

Right now, the App Registration exists but has zero permissions in Azure. We need to give it the **Artifact Signing Certificate Profile Signer** role on the certificate profile (or on the account — both work, but profile-level is tighter).

### 3a. Navigate to role assignment

1. Top search bar: type **`Artifact Signing`** and click **"Artifact Signing Accounts"**.
2. Click your account → in the left menu, click **"Certificate profiles"**.
3. Click the specific certificate profile you'll use for signing.
4. In the **profile's** left menu, click **"Access control (IAM)"**.
   - **Important:** make sure you're on the certificate PROFILE's IAM blade, not the account's IAM blade. Profile-scoped role assignment is more secure.

### 3b. Add the role assignment

1. Click the **"+ Add"** button at the top, then **"Add role assignment"** from the dropdown.
2. **Role tab:** in the search filter, type **`Artifact Signing Certificate Profile Signer`** and select that role.
   - It may also appear as **"Trusted Signing Certificate Profile Signer"** if your portal hasn't fully updated to the rebrand. Either is correct; they're the same role.
   - Click **"Next"** at the bottom.
3. **Members tab:**
   - **Assign access to:** select **"User, group, or service principal"** (NOT "Managed identity").
   - Click **"+ Select members"**.
   - In the search box that appears, type **`tiny11options-github-signer`** (your App Registration name from Part 2a).
   - It should show up in the dropdown. Click it to select.
     - **Note:** Microsoft's docs warn that "Only users will be listed by default" — if the App Registration doesn't appear, click outside the search box, then click "+ Select members" again. Sometimes you need to type the FULL name before service principals show.
   - Click **"Select"** at the bottom of that panel.
   - Click **"Next"**.
4. **Review + assign tab:** check the role + member look right, then click **"Review + assign"**.

You should see a notification: "Added role assignment".

### Checkpoint

In Access control (IAM) → **Role assignments** tab, you should see:
- **Role:** Artifact Signing Certificate Profile Signer (or Trusted Signing Certificate Profile Signer)
- **Name:** tiny11options-github-signer (your App Registration)
- **Type:** App
- **Scope:** This resource (the certificate profile)

---

## Part 4 — Add the 5 GitHub repo secrets

1. Open <https://github.com/bilbospocketses/tiny11options> in a browser, signed in as a repo admin.
2. Click **"Settings"** (top-right, next to Pull requests / Actions / etc.).
3. In the left menu, expand **"Secrets and variables"** → click **"Actions"**.
4. Click **"New repository secret"** at the top-right.
5. For each of the 5 secrets, repeat:
   - **Name:** the exact secret name (case-sensitive, matches the table below)
   - **Secret:** the value you copied earlier
   - Click **"Add secret"**

| Name | Source |
|---|---|
| `AZURE_TENANT_ID` | Part 2b — Directory (tenant) ID |
| `AZURE_CLIENT_ID` | Part 2b — Application (client) ID |
| `TRUSTED_SIGNING_ENDPOINT` | Part 1a — full URL including `https://` |
| `TRUSTED_SIGNING_ACCOUNT` | Part 1b — account name |
| `TRUSTED_SIGNING_CERT_PROFILE` | Part 1c — certificate profile name |

### Checkpoint

The "Repository secrets" section should list all 5 names. GitHub does NOT show the values back (security feature) — if you mistyped a value, you'll only find out when the workflow runs. Triple-check during entry.

---

## Part 5 — Verify the wiring with a smoke test

Before tagging v1.0.0 (which is a real release), do a smoke test with a throwaway pre-release tag to confirm signing works end-to-end.

### 5a. Push a smoke tag

From your terminal in `C:\Users\jscha\source\repos\tiny11options`:

```powershell
git checkout feat/path-c-launcher
git tag v0.99.0-smoketest
git push origin v0.99.0-smoketest
```

### 5b. Watch the workflow

1. Go to <https://github.com/bilbospocketses/tiny11options/actions>.
2. You should see a workflow run named **"release"** triggered by the tag push. Click it.
3. Watch each step. The ones most likely to fail on first run:
   - **"Sign tiny11options.exe via Trusted Signing"** — fails if any of the 5 secrets is wrong or the role assignment didn't propagate. Error message will tell you which.
   - **"Velopack pack"** — fails if `vpk` couldn't install or `--releaseNotes` file can't be read.
   - **"Sign Velopack artifacts via Trusted Signing"** — same as the first sign step but for the .nupkg + Setup.exe.

### 5c. If signing fails — common gotchas

| Error | Likely cause |
|---|---|
| `AADSTS70021: No matching federated identity record found` | Federated credential subject doesn't match. Edit it and verify the entity type is **Tag** and tag pattern is `v*`. |
| `Forbidden` or `403` from Trusted Signing endpoint | Role assignment hasn't propagated yet (can take a few minutes after assignment), OR the role is assigned to the wrong scope (account-level vs profile-level mismatch). Wait 5-10 minutes and re-run the workflow, or re-check the IAM blade. |
| `Endpoint URL not found` or DNS error | Endpoint secret value is wrong (missing `https://`, wrong region code, trailing slash). |
| `Account 'xxx' not found` | `TRUSTED_SIGNING_ACCOUNT` secret doesn't match the account name. Case-insensitive, but typo-sensitive. |
| `Certificate profile 'xxx' not found` | `TRUSTED_SIGNING_CERT_PROFILE` secret doesn't match. |

### 5d. Clean up after smoke test

If the workflow succeeded, you'll have a `v0.99.0-smoketest` release listed at <https://github.com/bilbospocketses/tiny11options/releases>. Delete it:

```powershell
git push --delete origin v0.99.0-smoketest
git tag --delete v0.99.0-smoketest
gh release delete v0.99.0-smoketest --yes
```

(Or do it from the GitHub Releases UI.)

### 5e. Ready for v1.0.0

Once 5a-5d pass cleanly:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

Workflow runs, signs, packs, releases. You're done.

---

## Troubleshooting / FAQ

**Q: I see "Trusted Signing" some places and "Artifact Signing" others. Which is right?**
A: Both. Microsoft rebranded the service in 2025. Azure Portal blades and role names are updated to "Artifact Signing". The GitHub Action is still at `azure/trusted-signing-action`. Our `release.yml` secret names use the older "TRUSTED_SIGNING_*" prefix to match the action's input parameter names.

**Q: Can I assign the signing role at the Artifact Signing account level instead of per-profile?**
A: Yes — the role is inherited downward. Account-level is fine if you only have one certificate profile or use them all from this workflow. Profile-level is tighter (least-privilege) which is why this guide recommends it.

**Q: The federated credential supports a "branch" entity type — could I use that to sign untagged commits too?**
A: You could, but don't. Tag-scoped signing keeps the signed binary corpus matched to your release process. Untagged signs would create build artifacts that nobody knows the provenance of and don't appear in your Releases page.

**Q: How much will Trusted Signing cost me?**
A: About $10/month flat (Basic tier) plus a small per-signature fee that's negligible at our release cadence (a few signs per release × a few releases per month = pennies).

**Q: Do I need to rotate any secrets periodically?**
A: No — OIDC federation has no rotating client secrets. The federated credential itself is permanent until you delete it. The trust is anchored on the GitHub Actions OIDC issuer + the specific repo + tag pattern, which can't be impersonated without compromising GitHub itself.

**Q: What if I want to allow other branches/repos to sign in the future?**
A: Add additional federated credentials on the same App Registration. Each credential is independently scoped. No need to create a new App Registration per repo unless you want strict per-repo permission boundaries.
