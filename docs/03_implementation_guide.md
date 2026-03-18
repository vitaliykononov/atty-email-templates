# Atty.ai Email Automation — Developer Implementation Guide

**Version:** 2.0  
**Date:** March 2026  
**Author:** Vitaliy Kononov  
**For:** Stanislav Davydenko (Backend), Andrii Kondratiuk (Frontend), Vlad

---

## Architecture Overview

```
VAPI Webhooks ──────┐
Stripe Webhooks ────┤
App Events ─────────┼──► Backend API ──► PostgreSQL (can_send_email gate) ──► SendGrid API
pg_cron Scheduler ──┘         │                                                    │
                              └──── email_log table (dedup/tracking) ◄──────────────┘
```

**Stack:**
- **Database:** PostgreSQL (main app DB)
- **Email delivery:** SendGrid v3 Mail Send API with Dynamic Templates
- **Scheduling:** pg_cron or backend cron jobs
- **Triggers:** Webhook handlers (VAPI, Stripe) + app event hooks + scheduled queries

---

## Implementation Phases

### Phase 1: Foundation (Days 1-3)
1. Run `01_schema.sql` against PostgreSQL
2. Create 4 SendGrid Suppression Groups (see below)
3. Update `sendgrid_suppression_groups` table with actual group IDs
4. Upload first 5 templates to SendGrid (welcome, setup_complete, first_call, call_notification, password_reset)
5. Update `email_templates` table with actual SendGrid template IDs
6. Implement `sendEmail()` helper function in backend
7. Wire up: user signup → welcome email

### Phase 2: Onboarding + Core Usage (Days 4-7)
1. Upload remaining onboarding templates (setup_nudge_1-4, test_call_nudge)
2. Upload usage templates (daily_digest, weekly_report, daily_report, feature_education)
3. Implement pg_cron job: hourly setup nudge check
4. Wire up: VAPI webhook → call_notification + first_call
5. Implement pg_cron job: Monday 8am weekly report
6. Implement pg_cron job: daily 8am digest for digest-pref users

### Phase 3: Trial + Billing (Days 8-12)
1. Upload trial templates (trial_ending_3days, trial_ending_1day, trial_expired, subscription_confirmed)
2. Upload all billing templates (credit warnings, payment failures, invoice, plan changes)
3. Implement pg_cron job: daily trial countdown check
4. Wire up: Stripe webhooks → payment_failed, payment_recovered, subscription events
5. Wire up: credit threshold checks after each call

### Phase 4: Engagement + Retention (Days 13-16)
1. Upload engagement templates (milestones, NPS, referral, upsell)
2. Upload retention templates (inactive_7/14/21 days)
3. Implement pg_cron job: daily inactivity check
4. Implement pg_cron job: daily NPS eligibility check
5. Wire up: milestone triggers after call count updates

### Phase 5: Cancel/Winback + Product Updates + Cart Abandon (Days 17-20)
1. Upload cancel/winback templates
2. Upload product update templates
3. Upload cart abandon templates
4. Wire up: cancel flow in app → cancel_survey, save_offer, cancel_confirmed
5. Implement pg_cron job: daily winback eligibility check
6. Implement pg_cron job: hourly cart abandon check
7. Create admin endpoint for sending product update broadcasts

---

## SendGrid Setup Checklist

### 1. Create Suppression Groups
Go to: Marketing → Unsubscribe Groups

| Group Name | Description | After creation, record the Group ID |
|---|---|---|
| Onboarding | Setup reminders, feature education, trial warnings | → UPDATE sendgrid_suppression_groups SET sendgrid_group_id = ??? |
| Usage Reports | Weekly and daily usage summaries | → UPDATE sendgrid_suppression_groups SET sendgrid_group_id = ??? |
| Marketing | Promotions, referrals, upsells, milestones, NPS, retention, winback | → UPDATE sendgrid_suppression_groups SET sendgrid_group_id = ??? |
| Product Updates | Feature announcements and monthly changelogs | → UPDATE sendgrid_suppression_groups SET sendgrid_group_id = ??? |

### 2. Create Dynamic Templates
Go to: Email API → Dynamic Templates

For each HTML file in `email_templates/`:
1. Create Dynamic Template → name it matching template_key (e.g., `atty-welcome`)
2. Add Version → Code Editor → paste full HTML
3. Settings sidebar → set Subject and Preheader
4. Save → Make Active
5. Copy Template ID → UPDATE email_templates SET sendgrid_id = 'd-xxx' WHERE template_key = '...'

### 3. Configure Sender
Go to: Settings → Sender Authentication
- Verify domain: atty.ai
- From: hello@atty.ai
- Reply-to: support@atty.ai

### 4. Logo
Host logo at a public URL. Find-replace `https://atty.ai/logo.png` in ALL template HTML files before uploading. Recommended: 220x72px PNG with transparent background.

---

## Template Unsubscribe Classification

### Transactional (no unsubscribe, no ASM group):
These are triggered by user actions or critical service events. They always send.

- welcome, setup_complete, first_call
- call_notification, daily_digest
- subscription_confirmed, cancel_confirmed
- credit_warning_75, credit_warning_90, credit_limit_reached
- monthly_invoice, renewal_reminder
- payment_failed_1/2/final, payment_recovered, service_suspended
- plan_upgraded, plan_downgraded
- maintenance_notice, maintenance_complete
- password_reset, email_change, security_alert

### Commercial (requires unsubscribe via ASM group):

| Suppression Group | Templates |
|---|---|
| onboarding | setup_nudge_1/2/3/final, test_call_nudge, feature_education, trial_ending_3days/1day, trial_expired, no_calls_troubleshoot |
| usage_reports | weekly_report, daily_report |
| marketing | cart_abandon_1/2/3, milestone_100/500, nps_survey/promoter/detractor, referral_program, upsell_multiline, inactive_7/14/21days, cancel_survey, save_offer, winback_14/30/90days |
| product_updates | new_feature, product_changelog |

---

## Scheduled Jobs (pg_cron)

| Job | Schedule | What it does |
|---|---|---|
| setup_nudge_check | Every hour | Finds users with setup_completed_at IS NULL, sends appropriate nudge based on time since signup |
| trial_countdown | Daily 9am UTC | Finds trialing users approaching end, sends 3-day or 1-day warning |
| trial_expired_check | Daily 9am UTC | Finds expired trials, sends trial_expired |
| weekly_report | Monday 7am UTC | Sends weekly report to active users with <20 calls/week |
| daily_report | Daily 7am UTC | Sends daily report to active users with 20+ calls/week |
| daily_digest | Daily 7am UTC | Sends call digest to users with pref=digest |
| inactivity_check | Daily 10am UTC | Finds inactive users (7/14/21 days), sends appropriate retention email |
| nps_check | Daily 11am UTC | Finds users eligible for NPS survey (30+ days paid, 20+ calls, not surveyed) |
| winback_check | Daily 10am UTC | Finds churned users at 14/30/90 day marks, sends winback |
| cart_abandon_check | Every hour | Finds abandoned signups, sends cart abandon sequence |
| credit_check | After each call | Inline check: if minutes_used crosses 75/90/100% threshold, send warning |
| renewal_reminder | Daily 9am UTC | Finds users with current_period_end within 7 days, sends reminder |

**Timezone handling:** All morning emails should be sent at 8am in the user's local timezone. Store timezone in users table, convert UTC cron to per-user send times. Default to America/New_York.

---

## Anti-Overwhelm Rules (enforced in can_send_email function)

1. **Daily cap:** Max 1 system email per day per user (call notifications and daily digests are exempt)
2. **Priority override:** Only priority 1-3 emails (payment failures, trial expiry, credit warnings) can override the daily cap
3. **Dedup:** Same template cannot be sent to same user within cooldown_hours (default 7 days)
4. **Lifetime cap:** max_sends_per_user limits total sends (most one-time emails = 1, reports = 999)
5. **Sequence termination:** After the final email in any nurture sequence, no more emails in that sequence
6. **Timezone window:** Scheduled emails only send between 8am-6pm user local time

---

## Key Database Queries for Frontend

### Email preferences page (Andrii)
```sql
SELECT call_notification_pref, timezone FROM users WHERE id = $1;

SELECT sg.group_key, sg.name, sg.description
FROM sendgrid_suppression_groups sg;
-- Actual unsub status is managed by SendGrid.
-- Frontend should link to SendGrid preference page or build custom using SendGrid API.
```

### Email history page
```sql
SELECT el.template_key, et.name, el.sent_at, el.status, el.opened_at, el.clicked_at
FROM email_log el
JOIN email_templates et ON et.template_key = el.template_key
WHERE el.user_id = $1
ORDER BY el.sent_at DESC
LIMIT 50;
```

---

## SendGrid Event Webhook (optional but recommended)

Set up SendGrid Event Webhook to POST delivery events back to your backend at `POST /webhooks/sendgrid/events`. Update email_log with delivery status:

```sql
UPDATE email_log 
SET status = $1, 
    delivered_at = CASE WHEN $1 = 'delivered' THEN $2 END,
    opened_at = CASE WHEN $1 = 'open' THEN $2 END,
    clicked_at = CASE WHEN $1 = 'click' THEN $2 END
WHERE sendgrid_template_id = $3 
  AND user_id = $4 
  AND sent_at > NOW() - INTERVAL '7 days';
```

---

## Files in This Package

| File | Purpose |
|---|---|
| `01_schema.sql` | PostgreSQL tables, functions, seed data, and reference queries |
| `02_journey_diagram.mermaid` | Full customer journey flowchart (paste into mermaid.live) |
| `03_implementation_guide.md` | This file |
| `email_templates/` | 54 HTML email templates ready to paste into SendGrid |
| `email_templates/README.md` | Quick-reference index of all templates |
