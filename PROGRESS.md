# Email Automation — Implementation Progress

**Status:** 3 PRs open for review (all independent). 13 of 55 SendGrid templates uploaded. Tiers 2 + 3 complete. Next: Tier 4 (billing & credits).

---

## Open PRs (all independent, merge in any order)

**PR #190 — Tier 2 Config:** https://github.com/atty-ai/atty-be/pull/190
- Branch: `feature/email-automation-config`
- 8 new template entries: setupComplete, firstCall, setupNudge1/2/3/final, testCallNudge, noCallsTroubleshoot
- 5 new send methods on EmailService
- Env vars in env.example (commented out)

**PR #191 — Tier 2 Triggers:** https://github.com/atty-ai/atty-be/pull/191
- Branch: `feature/email-automation-triggers`
- Cherry-picks PR #190
- firstCall → `vapi.service.ts:trySendFirstCallEmail()` (counts calls, sends if first)
- setupComplete → `onboarding-sync.service.ts:trySendSetupCompleteEmail()` (after onboarding)
- Setup nudge 1/2/3/final → refactored `onboarding-reminder.worker.ts` (12h→36h→3d→5d, falls back to legacy)
- Added EmailModule to OnboardingModule, added `isTemplateConfigured()` on EmailService

**PR #192 — Tier 3 Trial Lifecycle:** https://github.com/atty-ai/atty-be/pull/192
- Branch: `feature/email-trial-lifecycle`
- 4 new template entries: trialEnding3days, trialEnding1day, trialExpired, subscriptionConfirmed
- 3 new send methods on EmailService
- NEW `TrialCountdownWorker` cron (daily 1PM UTC / 9AM ET) — queries `subscriptions.trialEndAt`
- subscriptionConfirmed trigger in `stripe.service.ts:handleSubscriptionCreated()`
- EmailModule added to StripeModule + BillingModule
- No migrations — uses existing `Subscription.trialEndAt`

---

## Env Vars to Set After Merge

### Tier 2 (PR #190/#191)
```bash
SENDGRID_SETUP_COMPLETE_TEMPLATE_ID=d-9feba59e2cc14aaaa451446397223be9
SENDGRID_FIRST_CALL_TEMPLATE_ID=d-74b2e1dd24e649fbabf30055cc9d0c02
SENDGRID_SETUP_NUDGE_1_TEMPLATE_ID=d-e029946e8a9649d09969c991a05e583a
SENDGRID_SETUP_NUDGE_2_TEMPLATE_ID=d-ace57dd9efab4752b020f7f7b9edf20a
SENDGRID_SETUP_NUDGE_3_TEMPLATE_ID=d-171ac61b86ae46a48229f557d4b34609
SENDGRID_SETUP_NUDGE_FINAL_TEMPLATE_ID=d-22617a62c440474cb071ba66c0b9a0ab
SENDGRID_TEST_CALL_NUDGE_TEMPLATE_ID=d-7b4244645840407486652e48ddbdd1cf
SENDGRID_NO_CALLS_TROUBLESHOOT_TEMPLATE_ID=d-ba3f5039b20a41108cd1cc3d89d7cc7c
```

### Tier 3 (PR #192)
```bash
SENDGRID_TRIAL_ENDING_3DAYS_TEMPLATE_ID=d-4bbcaf542e784f13949840c8c17d5e96
SENDGRID_TRIAL_ENDING_1DAY_TEMPLATE_ID=d-91bc2c83f98142e58a0f876600b6d2ce
SENDGRID_TRIAL_EXPIRED_TEMPLATE_ID=d-198ca415fdeb4979a1ddc892e7dd3c7a
SENDGRID_SUBSCRIPTION_CONFIRMED_TEMPLATE_ID=d-7288dd8e7c4c4ae98d3e8a1c0a134c86
```

---

## SendGrid Upload Progress (13 of 55)

| Template Name | SendGrid ID |
|---|---|
| `atty-cart-abandon-1` | `d-e6d6c2a4635247b98e4f8b6b46dac39f` |
| `atty-setup-complete` | `d-9feba59e2cc14aaaa451446397223be9` |
| `atty-first-call` | `d-74b2e1dd24e649fbabf30055cc9d0c02` |
| `atty-setup-nudge-1` | `d-e029946e8a9649d09969c991a05e583a` |
| `atty-setup-nudge-2` | `d-ace57dd9efab4752b020f7f7b9edf20a` |
| `atty-setup-nudge-3` | `d-171ac61b86ae46a48229f557d4b34609` |
| `atty-setup-nudge-final` | `d-22617a62c440474cb071ba66c0b9a0ab` |
| `atty-test-call-nudge` | `d-7b4244645840407486652e48ddbdd1cf` |
| `atty-no-calls-troubleshoot` | `d-ba3f5039b20a41108cd1cc3d89d7cc7c` |
| `atty-trial-ending-3days` | `d-4bbcaf542e784f13949840c8c17d5e96` |
| `atty-trial-ending-1day` | `d-91bc2c83f98142e58a0f876600b6d2ce` |
| `atty-trial-expired` | `d-198ca415fdeb4979a1ddc892e7dd3c7a` |
| `atty-subscription-confirmed` | `d-7288dd8e7c4c4ae98d3e8a1c0a134c86` |

---

## Tier Progress

### Tier 2 — Onboarding & Activation: DONE
- setupComplete, firstCall, setupNudge1/2/3/final, testCallNudge, noCallsTroubleshoot
- Config + methods + triggers all wired
- Note: testCallNudge and noCallsTroubleshoot have config+methods but triggers NOT yet wired

### Tier 3 — Trial Lifecycle: DONE
- trialEnding3days, trialEnding1day, trialExpired, subscriptionConfirmed
- Config + methods + TrialCountdownWorker cron + Stripe trigger all wired

### Tier 4 — Billing & Credits: NEXT
- 12 templates: credit-warning-75/90, credit-limit-reached, monthly-invoice, renewal-reminder, payment-failed-1/2/final, payment-recovered, plan-upgraded/downgraded, service-suspended
- Existing Stripe webhook handlers to extend:
  - `invoice.paid` handler → monthly invoice email
  - `subscription-updated` handler → plan upgraded/downgraded
  - `subscription-deleted` handler → cancel confirmed (or service suspended)
  - **NEW** `invoice.payment_failed` handler needed
- Credit threshold checks (75/90/100%) → post-call in vapi.service.ts or usage service
- renewal-reminder → new cron job querying `subscription.periodEndAt`

### Tier 5 — Engagement + Retention + Winback: LATER
- ~18 templates: milestones, NPS, referral, upsell, inactivity, cancel flow, winback, cart abandon
- Multiple new cron jobs + cancel flow + cart abandon table

---

## Architecture Notes

- **Backend:** atty-be (NestJS + Prisma + PostgreSQL)
- **Table:** `merchants` (model `Merchant`), firm name at `MerchantProfile.firmTitle`
- **Subscriptions:** `subscriptions` table with `trialStartAt`, `trialEndAt`, `status`, `periodStartAt`, `periodEndAt`
- **Plans:** `plans` table with `title`, `amount`, `monthlyUnits`
- **Stripe handlers:** Strategy pattern at `src/integrations/stripe/handlers/`
- **Email pattern:** add to `EMAIL_TEMPLATES` + env var + method on `EmailService` + trigger (all guard with `isTemplateConfigured`)
- **All templates use camelCase variables** (converted from original snake_case)

## Known Issues
- Logo URL `https://atty.ai/logo.png` — needs real hosted logo
- Footer says "Jonie AI LLC" — verify entity name
- Existing Onboarding Reminder has "Jonie" branding — fixed when nudge templates go live
