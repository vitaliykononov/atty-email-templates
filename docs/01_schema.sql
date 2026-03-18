-- ============================================================
-- ATTY.AI EMAIL AUTOMATION SYSTEM
-- PostgreSQL Schema & Implementation Reference
-- ============================================================
-- 
-- Architecture:
--   PostgreSQL (main DB) -> Backend -> SendGrid API
--   VAPI webhooks -> Backend -> PostgreSQL + SendGrid
--   Stripe webhooks -> Backend -> PostgreSQL + SendGrid
--   pg_cron -> Backend scheduled jobs -> SendGrid
-- ============================================================


-- ============================================================
-- 1. REQUIRED FIELDS ON USERS TABLE
-- ============================================================
-- Add these columns to your existing users table.
-- Listed as reference. Run as ALTER TABLE ADD COLUMN IF NOT EXISTS.

/*
  -- Onboarding / Activation
  setup_completed_at      TIMESTAMPTZ     -- NULL = not done
  setup_step_current      SMALLINT        -- 1=firm details, 2=forwarding, 3=test call
  test_call_completed_at  TIMESTAMPTZ
  first_real_call_at      TIMESTAMPTZ

  -- Trial
  trial_start_date        TIMESTAMPTZ NOT NULL DEFAULT NOW()
  trial_end_date          TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '14 days')
  
  -- Subscription (synced from Stripe webhooks)
  stripe_customer_id      TEXT
  stripe_subscription_id  TEXT
  subscription_status     TEXT            -- 'trialing','active','past_due','canceled','paused'
  plan_name               TEXT
  plan_minutes            INTEGER
  plan_price_cents        INTEGER
  current_period_start    TIMESTAMPTZ
  current_period_end      TIMESTAMPTZ
  card_last4              TEXT
  card_brand              TEXT

  -- Usage tracking
  minutes_used_current    INTEGER DEFAULT 0
  total_calls_all_time    INTEGER DEFAULT 0
  total_messages_captured INTEGER DEFAULT 0
  
  -- Activity
  last_call_at            TIMESTAMPTZ
  last_login_at           TIMESTAMPTZ
  
  -- Feedback
  nps_score               SMALLINT        -- 0-10, NULL = not surveyed
  nps_last_sent_at        TIMESTAMPTZ
  
  -- Referral
  referral_code           TEXT UNIQUE
  referred_by_user_id     UUID REFERENCES users(id)
  
  -- Notification preferences
  call_notification_pref  TEXT DEFAULT 'realtime'  -- 'realtime','digest','off'
  timezone                TEXT DEFAULT 'America/New_York'
  
  -- Cart abandon
  signup_email_captured   TEXT
  signup_abandoned_at     TIMESTAMPTZ
*/


-- ============================================================
-- 2. EMAIL LOG TABLE (deduplication & tracking)
-- ============================================================

CREATE TABLE IF NOT EXISTS email_log (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    template_key    TEXT NOT NULL,
    sendgrid_template_id TEXT,
    subject         TEXT,
    status          TEXT DEFAULT 'sent',     -- 'sent','delivered','opened','clicked','bounced','failed'
    suppression_group_id INTEGER,
    metadata        JSONB DEFAULT '{}',
    sent_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    delivered_at    TIMESTAMPTZ,
    opened_at       TIMESTAMPTZ,
    clicked_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_email_log_user_template ON email_log(user_id, template_key);
CREATE INDEX idx_email_log_user_sent ON email_log(user_id, sent_at DESC);
CREATE INDEX idx_email_log_template_sent ON email_log(template_key, sent_at DESC);


-- ============================================================
-- 3. EMAIL TEMPLATES REGISTRY
-- ============================================================

CREATE TABLE IF NOT EXISTS email_templates (
    id              SERIAL PRIMARY KEY,
    template_key    TEXT UNIQUE NOT NULL,
    sendgrid_id     TEXT NOT NULL,               -- d-xxx from SendGrid
    category        TEXT NOT NULL,
    name            TEXT NOT NULL,
    subject_line    TEXT NOT NULL,
    is_transactional BOOLEAN DEFAULT FALSE,
    suppression_group TEXT,                      -- NULL for transactional
    max_sends_per_user INTEGER DEFAULT 1,
    cooldown_hours  INTEGER DEFAULT 168,         -- 7 days default
    priority        SMALLINT DEFAULT 5,          -- 1=highest, 10=lowest
    active          BOOLEAN DEFAULT TRUE,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- Seed all 54 templates
-- Replace 'd-REPLACE' with actual SendGrid IDs after template creation

INSERT INTO email_templates (template_key, sendgrid_id, category, name, subject_line, is_transactional, suppression_group, max_sends_per_user, priority) VALUES

-- PHASE 0: Cart Abandon
('cart_abandon_1',      'd-REPLACE', 'cart_abandon',     'Cart Abandon 1',                  'You left something behind — your AI receptionist is waiting',              FALSE, 'marketing',        1, 8),
('cart_abandon_2',      'd-REPLACE', 'cart_abandon',     'Cart Abandon 2',                  '67% of callers wont leave a voicemail — are you losing clients?',          FALSE, 'marketing',        1, 8),
('cart_abandon_3',      'd-REPLACE', 'cart_abandon',     'Cart Abandon 3 Final',            'Still interested? See Atty.ai in action (60-second demo)',                 FALSE, 'marketing',        1, 9),

-- PHASE 1: Onboarding
('welcome',             'd-REPLACE', 'onboarding',       'Welcome',                          'Welcome to Atty.ai — 3 steps to never miss a call again',                TRUE,  NULL,               1, 2),
('setup_nudge_1',       'd-REPLACE', 'onboarding',       'Setup Nudge 1',                    'Your AI receptionist needs 4 more minutes',                               FALSE, 'onboarding',       1, 4),
('setup_nudge_2',       'd-REPLACE', 'onboarding',       'Setup Nudge 2',                    'Every missed call is a missed client — finish setup today',                FALSE, 'onboarding',       1, 4),
('setup_nudge_3',       'd-REPLACE', 'onboarding',       'Setup Nudge 3',                    'Need a hand setting up? We are here to help',                             FALSE, 'onboarding',       1, 4),
('setup_nudge_final',   'd-REPLACE', 'onboarding',       'Setup Nudge Final',                '{{days_left}} days left on your trial — dont let it expire unused',        FALSE, 'onboarding',       1, 4),
('setup_complete',      'd-REPLACE', 'onboarding',       'Setup Complete',                   'You are live! Your AI receptionist is answering calls',                    TRUE,  NULL,               1, 2),
('test_call_nudge',     'd-REPLACE', 'onboarding',       'Test Call Nudge',                  'Have you called your AI receptionist yet?',                                FALSE, 'onboarding',       1, 5),

-- PHASE 2: Activation
('first_call',          'd-REPLACE', 'activation',       'First Call Handled',               'Your AI receptionist just handled its first real call',                    TRUE,  NULL,               1, 2),
('no_calls_troubleshoot','d-REPLACE','activation',       'No Calls Troubleshoot',            'No calls yet — is your call forwarding active?',                           FALSE, 'onboarding',       1, 5),

-- PHASE 3: Active Usage
('call_notification',   'd-REPLACE', 'usage',            'Call Notification',                'New message from {{caller_name}} — {{call_summary_short}}',                TRUE,  NULL,               999, 1),
('daily_digest',        'd-REPLACE', 'usage',            'Daily Digest',                     'Yesterday: {{calls_count}} calls answered for {{firm_name}}',              TRUE,  NULL,               999, 3),
('weekly_report',       'd-REPLACE', 'usage',            'Weekly Report',                    'Weekly report: {{total_calls}} calls answered for {{firm_name}}',          FALSE, 'usage_reports',    999, 6),
('daily_report',        'd-REPLACE', 'usage',            'Daily Report High Volume',         'Yesterday: {{calls_yesterday}} calls answered',                            FALSE, 'usage_reports',    999, 6),
('feature_education',   'd-REPLACE', 'usage',            'Feature Education',                '3 things your AI receptionist can do that you might not know',             FALSE, 'onboarding',       1, 7),

-- PHASE 4: Trial Lifecycle
('trial_ending_3days',  'd-REPLACE', 'trial',            'Trial Ending 3 Days',              '3 days left — here is what you will lose',                                 FALSE, 'onboarding',       1, 2),
('trial_ending_1day',   'd-REPLACE', 'trial',            'Trial Ending 1 Day',               'Tomorrow: your AI receptionist goes offline',                              FALSE, 'onboarding',       1, 1),
('trial_expired',       'd-REPLACE', 'trial',            'Trial Expired',                    'Your AI receptionist is now offline',                                      FALSE, 'onboarding',       1, 2),
('subscription_confirmed','d-REPLACE','trial',           'Subscription Confirmed',           'Subscription confirmed — you are all set',                                 TRUE,  NULL,               1, 2),

-- PHASE 5: Billing & Credits
('credit_warning_75',   'd-REPLACE', 'billing',          'Credit Warning 75%',               'Heads up: you have used 75% of your monthly minutes',                      TRUE,  NULL,               1, 3),
('credit_warning_90',   'd-REPLACE', 'billing',          'Credit Warning 90%',               '{{minutes_remaining}} minutes remaining on your plan',                     TRUE,  NULL,               1, 2),
('credit_limit_reached','d-REPLACE', 'billing',          'Credit Limit Reached',             'You have used all {{plan_minutes}} minutes this month',                    TRUE,  NULL,               1, 2),
('monthly_invoice',     'd-REPLACE', 'billing',          'Monthly Invoice',                  'Your Atty.ai invoice: ${{total_amount}}',                                  TRUE,  NULL,               999, 3),
('renewal_reminder',    'd-REPLACE', 'billing',          'Renewal Reminder',                 'Your plan renews on {{renewal_date}}: ${{amount}}',                        TRUE,  NULL,               999, 4),
('payment_failed_1',    'd-REPLACE', 'billing',          'Payment Failed 1',                 'Action needed: payment of ${{amount}} failed',                             TRUE,  NULL,               1, 1),
('payment_failed_2',    'd-REPLACE', 'billing',          'Payment Failed 2',                 'Second notice: payment still failing for {{firm_name}}',                   TRUE,  NULL,               1, 1),
('payment_failed_final','d-REPLACE', 'billing',          'Payment Failed Final',             'Final notice: your AI receptionist will be paused tomorrow',               TRUE,  NULL,               1, 1),
('payment_recovered',   'd-REPLACE', 'billing',          'Payment Recovered',                'Payment processed — you are all set',                                      TRUE,  NULL,               999, 2),
('service_suspended',   'd-REPLACE', 'billing',          'Service Suspended',                'Your AI receptionist has been paused',                                     TRUE,  NULL,               1, 1),
('plan_upgraded',       'd-REPLACE', 'billing',          'Plan Upgraded',                    'Plan upgraded to {{new_plan_name}} — new limits active now',               TRUE,  NULL,               999, 3),
('plan_downgraded',     'd-REPLACE', 'billing',          'Plan Downgraded',                  'Plan changed to {{new_plan_name}}',                                        TRUE,  NULL,               999, 3),

-- PHASE 6: Milestones & Growth
('milestone_100',       'd-REPLACE', 'engagement',       'Milestone 100 Calls',              '100 calls answered — here is your impact',                                 FALSE, 'marketing',        1, 8),
('milestone_500',       'd-REPLACE', 'engagement',       'Milestone 500 Calls',              '500 calls answered — you are a power user',                                FALSE, 'marketing',        1, 8),
('nps_survey',          'd-REPLACE', 'engagement',       'NPS Survey',                       'One quick question about Atty.ai',                                         FALSE, 'marketing',        1, 7),
('nps_promoter',        'd-REPLACE', 'engagement',       'NPS Promoter Follow-up',           'Thanks for the kind words! Want to help us grow?',                         FALSE, 'marketing',        1, 8),
('nps_detractor',       'd-REPLACE', 'engagement',       'NPS Detractor Follow-up',          'We hear you — let us fix this',                                            FALSE, 'marketing',        1, 7),
('referral_program',    'd-REPLACE', 'engagement',       'Referral Program',                 'Give a month, get a month — Atty.ai referral program',                     FALSE, 'marketing',        1, 8),
('upsell_multiline',    'd-REPLACE', 'engagement',       'Multi-Line Upsell',                'Handle multiple lines with Atty.ai',                                       FALSE, 'marketing',        1, 8),

-- PHASE 7: Retention
('inactive_7days',      'd-REPLACE', 'retention',        'Inactive 7 Days',                  'No calls in 7 days — is everything working?',                              FALSE, 'marketing',        1, 5),
('inactive_14days',     'd-REPLACE', 'retention',        'Inactive 14 Days Case Study',      'How firms capture 15+ leads per month with Atty.ai',                       FALSE, 'marketing',        1, 6),
('inactive_21days',     'd-REPLACE', 'retention',        'Inactive 21 Days Final',           'Should we keep your AI receptionist active?',                              FALSE, 'marketing',        1, 5),

-- PHASE 8: Cancel & Winback
('cancel_survey',       'd-REPLACE', 'cancel_winback',   'Cancel Survey',                    'Before you go — can you tell us why?',                                     FALSE, 'marketing',        1, 4),
('save_offer',          'd-REPLACE', 'cancel_winback',   'Save Offer',                       'We would like to offer you 50% off for 2 months',                          FALSE, 'marketing',        1, 3),
('cancel_confirmed',    'd-REPLACE', 'cancel_winback',   'Cancellation Confirmed',           'Your Atty.ai subscription has been canceled',                              TRUE,  NULL,               1, 2),
('winback_14days',      'd-REPLACE', 'cancel_winback',   'Winback 14 Days',                  'Estimated missed calls since you left',                                    FALSE, 'marketing',        1, 7),
('winback_30days',      'd-REPLACE', 'cancel_winback',   'Winback 30 Days',                  'We have improved since you left — come see what is new',                   FALSE, 'marketing',        1, 8),
('winback_90days',      'd-REPLACE', 'cancel_winback',   'Winback 90 Days Final',            'Your Atty.ai configuration expires in 30 days',                            FALSE, 'marketing',        1, 9),

-- PHASE 9: Product Updates
('new_feature',         'd-REPLACE', 'product_updates',  'New Feature Announcement',         'New in Atty.ai: {{feature_name}}',                                         FALSE, 'product_updates',  999, 7),
('product_changelog',   'd-REPLACE', 'product_updates',  'Monthly Changelog',                'What is new in Atty.ai — {{month_year}} update',                           FALSE, 'product_updates',  999, 7),
('maintenance_notice',  'd-REPLACE', 'product_updates',  'Maintenance Notice',               'Scheduled maintenance: {{maintenance_date}} at {{maintenance_time}}',       TRUE,  NULL,               999, 3),
('maintenance_complete','d-REPLACE', 'product_updates',  'Maintenance Complete',             'Maintenance complete — all systems operational',                            TRUE,  NULL,               999, 3),

-- PHASE 10: Transactional
('password_reset',      'd-REPLACE', 'transactional',    'Password Reset',                   'Reset your Atty.ai password',                                              TRUE,  NULL,               999, 1),
('email_change',        'd-REPLACE', 'transactional',    'Email Change',                     'Confirm your new email address',                                           TRUE,  NULL,               999, 1),
('security_alert',      'd-REPLACE', 'transactional',    'Security Alert',                   'New login to your Atty.ai account',                                        TRUE,  NULL,               999, 1)

ON CONFLICT (template_key) DO NOTHING;


-- ============================================================
-- 4. CART ABANDON TRACKING
-- ============================================================

CREATE TABLE IF NOT EXISTS cart_abandons (
    id              BIGSERIAL PRIMARY KEY,
    email           TEXT NOT NULL,
    resume_token    TEXT UNIQUE NOT NULL DEFAULT gen_random_uuid()::TEXT,
    form_data       JSONB DEFAULT '{}',
    abandoned_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    converted_at    TIMESTAMPTZ,
    emails_sent     SMALLINT DEFAULT 0,
    last_email_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cart_abandons_email ON cart_abandons(email);
CREATE INDEX idx_cart_abandons_unconverted ON cart_abandons(converted_at) WHERE converted_at IS NULL;


-- ============================================================
-- 5. SENDGRID SUPPRESSION GROUPS
-- ============================================================
-- Create these 4 groups in SendGrid dashboard, then update IDs here.

CREATE TABLE IF NOT EXISTS sendgrid_suppression_groups (
    group_key       TEXT PRIMARY KEY,
    sendgrid_group_id INTEGER NOT NULL,
    name            TEXT NOT NULL,
    description     TEXT
);

INSERT INTO sendgrid_suppression_groups (group_key, sendgrid_group_id, name, description) VALUES
('onboarding',      0, 'Onboarding',       'Setup reminders, feature education, trial warnings'),
('usage_reports',   0, 'Usage Reports',     'Weekly and daily usage summaries'),
('marketing',       0, 'Marketing',         'Promotions, referrals, upsells, milestones, NPS, winback'),
('product_updates', 0, 'Product Updates',   'Feature announcements and monthly changelogs')
ON CONFLICT (group_key) DO NOTHING;

-- After creating groups in SendGrid, update with actual IDs:
-- UPDATE sendgrid_suppression_groups SET sendgrid_group_id = <id> WHERE group_key = 'onboarding';
-- UPDATE sendgrid_suppression_groups SET sendgrid_group_id = <id> WHERE group_key = 'usage_reports';
-- UPDATE sendgrid_suppression_groups SET sendgrid_group_id = <id> WHERE group_key = 'marketing';
-- UPDATE sendgrid_suppression_groups SET sendgrid_group_id = <id> WHERE group_key = 'product_updates';


-- ============================================================
-- 6. HELPER FUNCTIONS
-- ============================================================

CREATE OR REPLACE FUNCTION can_send_email(
    p_user_id UUID,
    p_template_key TEXT
) RETURNS BOOLEAN AS $$
DECLARE
    v_template email_templates%ROWTYPE;
    v_send_count INTEGER;
    v_last_sent TIMESTAMPTZ;
    v_today_system_count INTEGER;
BEGIN
    SELECT * INTO v_template FROM email_templates WHERE template_key = p_template_key AND active = TRUE;
    IF NOT FOUND THEN RETURN FALSE; END IF;

    SELECT COUNT(*), MAX(sent_at) INTO v_send_count, v_last_sent
    FROM email_log
    WHERE user_id = p_user_id AND template_key = p_template_key;

    IF v_send_count >= v_template.max_sends_per_user THEN RETURN FALSE; END IF;

    IF v_last_sent IS NOT NULL AND
       v_last_sent > NOW() - (v_template.cooldown_hours || ' hours')::INTERVAL THEN
        RETURN FALSE;
    END IF;

    IF p_template_key NOT IN ('call_notification', 'daily_digest') THEN
        SELECT COUNT(*) INTO v_today_system_count
        FROM email_log
        WHERE user_id = p_user_id
          AND sent_at > CURRENT_DATE
          AND template_key NOT IN ('call_notification', 'daily_digest');

        IF v_today_system_count >= 1 THEN
            IF v_template.priority > 3 THEN RETURN FALSE; END IF;
        END IF;
    END IF;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION log_email_send(
    p_user_id UUID,
    p_template_key TEXT,
    p_sendgrid_template_id TEXT DEFAULT NULL,
    p_subject TEXT DEFAULT NULL,
    p_suppression_group_id INTEGER DEFAULT NULL,
    p_metadata JSONB DEFAULT '{}'
) RETURNS BIGINT AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO email_log (user_id, template_key, sendgrid_template_id, subject, suppression_group_id, metadata)
    VALUES (p_user_id, p_template_key, p_sendgrid_template_id, p_subject, p_suppression_group_id, p_metadata)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- 7. SCHEDULED JOB QUERIES (for pg_cron or backend cron)
-- ============================================================

-- 7a. Setup nudge candidates (run every hour)
/*
SELECT u.id, u.email, u.first_name, u.firm_name, u.timezone,
       EXTRACT(EPOCH FROM (NOW() - u.created_at)) / 3600 AS hours_since_signup,
       u.setup_step_current,
       EXTRACT(DAY FROM u.trial_end_date - NOW()) AS days_left
FROM users u
WHERE u.setup_completed_at IS NULL
  AND u.subscription_status = 'trialing'
  AND u.created_at > NOW() - INTERVAL '7 days'
  AND can_send_email(u.id, 
      CASE
          WHEN u.created_at < NOW() - INTERVAL '5 days' THEN 'setup_nudge_final'
          WHEN u.created_at < NOW() - INTERVAL '3 days' THEN 'setup_nudge_3'
          WHEN u.created_at < NOW() - INTERVAL '36 hours' THEN 'setup_nudge_2'
          WHEN u.created_at < NOW() - INTERVAL '12 hours' THEN 'setup_nudge_1'
          ELSE NULL
      END
  )
ORDER BY u.created_at;
*/

-- 7b. Trial ending candidates (run daily)
/*
SELECT u.id, u.email, u.first_name, u.firm_name, u.timezone,
       u.trial_end_date, u.total_calls_all_time, u.minutes_used_current
FROM users u
WHERE u.subscription_status = 'trialing'
  AND u.trial_end_date > NOW()
  AND (
      (u.trial_end_date BETWEEN NOW() AND NOW() + INTERVAL '1 day' 
       AND can_send_email(u.id, 'trial_ending_1day'))
      OR
      (u.trial_end_date BETWEEN NOW() + INTERVAL '2 days' AND NOW() + INTERVAL '3 days'
       AND can_send_email(u.id, 'trial_ending_3days'))
  );
*/

-- 7c. Weekly report candidates (run Monday 7am)
/*
SELECT u.id, u.email, u.first_name, u.firm_name, u.timezone,
       u.plan_name, u.plan_minutes, u.minutes_used_current
FROM users u
WHERE u.subscription_status IN ('active', 'trialing')
  AND u.setup_completed_at IS NOT NULL
  AND (SELECT COUNT(*) FROM calls c WHERE c.user_id = u.id AND c.created_at > NOW() - INTERVAL '7 days') < 20
  AND can_send_email(u.id, 'weekly_report');
*/

-- 7d. Inactivity check (run daily)
/*
SELECT u.id, u.email, u.first_name, u.firm_name, u.timezone,
       u.plan_name, u.plan_price_cents,
       EXTRACT(DAY FROM NOW() - COALESCE(u.last_call_at, u.setup_completed_at)) AS days_inactive
FROM users u
WHERE u.subscription_status = 'active'
  AND u.setup_completed_at IS NOT NULL
  AND COALESCE(u.last_call_at, u.setup_completed_at) < NOW() - INTERVAL '7 days'
  AND (
      (COALESCE(u.last_call_at, u.setup_completed_at) < NOW() - INTERVAL '21 days'
       AND can_send_email(u.id, 'inactive_21days'))
      OR
      (COALESCE(u.last_call_at, u.setup_completed_at) < NOW() - INTERVAL '14 days'
       AND can_send_email(u.id, 'inactive_14days'))
      OR
      (COALESCE(u.last_call_at, u.setup_completed_at) < NOW() - INTERVAL '7 days'
       AND can_send_email(u.id, 'inactive_7days'))
  )
ORDER BY days_inactive DESC;
*/

-- 7e. Cart abandon check (run every hour)
/*
SELECT ca.id, ca.email, ca.resume_token, ca.emails_sent, ca.abandoned_at
FROM cart_abandons ca
WHERE ca.converted_at IS NULL
  AND ca.emails_sent < 3
  AND (
      (ca.emails_sent = 0 AND ca.abandoned_at < NOW() - INTERVAL '1 hour')
      OR
      (ca.emails_sent = 1 AND ca.last_email_at < NOW() - INTERVAL '24 hours')
      OR
      (ca.emails_sent = 2 AND ca.last_email_at < NOW() - INTERVAL '3 days')
  );
*/

-- 7f. NPS survey candidates (run daily)
/*
SELECT u.id, u.email, u.first_name, u.firm_name
FROM users u
WHERE u.subscription_status = 'active'
  AND u.nps_score IS NULL
  AND u.nps_last_sent_at IS NULL
  AND u.current_period_start < NOW() - INTERVAL '30 days'
  AND u.total_calls_all_time >= 20
  AND can_send_email(u.id, 'nps_survey');
*/

-- 7g. Winback candidates (run daily)
/*
SELECT u.id, u.email, u.first_name, u.firm_name,
       EXTRACT(DAY FROM NOW() - u.current_period_end) AS days_since_churn
FROM users u
WHERE u.subscription_status IN ('canceled', 'unpaid')
  AND u.current_period_end < NOW()
  AND (
      (u.current_period_end < NOW() - INTERVAL '90 days'
       AND can_send_email(u.id, 'winback_90days'))
      OR
      (u.current_period_end < NOW() - INTERVAL '30 days'
       AND can_send_email(u.id, 'winback_30days'))
      OR
      (u.current_period_end < NOW() - INTERVAL '14 days'
       AND can_send_email(u.id, 'winback_14days'))
  )
ORDER BY days_since_churn ASC;
*/


-- ============================================================
-- 8. BACKEND PSEUDOCODE REFERENCE
-- ============================================================

/*
async function sendEmail(userId, templateKey, dynamicData = {}) {
    const canSend = await db.query('SELECT can_send_email($1, $2)', [userId, templateKey]);
    if (!canSend.rows[0].can_send_email) return { sent: false, reason: 'blocked_by_gate' };

    const template = await db.query(
        `SELECT et.*, sg.sendgrid_group_id 
         FROM email_templates et 
         LEFT JOIN sendgrid_suppression_groups sg ON sg.group_key = et.suppression_group 
         WHERE et.template_key = $1`, [templateKey]
    );

    const user = await db.query('SELECT * FROM users WHERE id = $1', [userId]);

    const payload = {
        personalizations: [{
            to: [{ email: user.email, name: user.first_name }],
            dynamic_template_data: { first_name: user.first_name, firm_name: user.firm_name, ...dynamicData }
        }],
        from: { email: 'hello@atty.ai', name: 'Atty.ai' },
        reply_to: { email: 'support@atty.ai', name: 'Atty.ai Support' },
        template_id: template.sendgrid_id
    };

    if (!template.is_transactional && template.sendgrid_group_id) {
        payload.asm = {
            group_id: template.sendgrid_group_id,
            groups_to_display: await getAllGroupIds()
        };
    }

    const response = await sendgrid.send(payload);
    await db.query('SELECT log_email_send($1, $2, $3, $4, $5, $6)',
        [userId, templateKey, template.sendgrid_id, template.subject_line, template.sendgrid_group_id, dynamicData]);

    return { sent: true };
}
*/

/*
EVENT HANDLERS:

// VAPI call completed webhook
app.post('/webhooks/vapi/call-completed', async (req, res) => {
    const call = req.body;
    const user = await getUserByPhoneNumber(call.phone_number);
    await db.query('UPDATE users SET total_calls_all_time = total_calls_all_time + 1, last_call_at = NOW() WHERE id = $1', [user.id]);

    if (user.total_calls_all_time === 0) {
        await sendEmail(user.id, 'first_call', { caller_name: call.caller_name, call_summary: call.summary, call_id: call.id });
    }
    if (user.call_notification_pref === 'realtime' && call.message_captured) {
        await sendEmail(user.id, 'call_notification', { caller_name: call.caller_name, call_summary: call.summary, call_id: call.id });
    }
});

// Stripe webhooks
app.post('/webhooks/stripe', async (req, res) => {
    const event = req.body;
    switch (event.type) {
        case 'invoice.payment_failed':
            const templateMap = { 1: 'payment_failed_1', 2: 'payment_failed_2', 3: 'payment_failed_final' };
            await sendEmail(user.id, templateMap[event.data.object.attempt_count], { amount, card_last4 });
            break;
        case 'invoice.paid':
            if (invoice.attempt_count > 1) await sendEmail(user.id, 'payment_recovered', { amount });
            break;
        case 'customer.subscription.deleted':
            await sendEmail(user.id, 'cancel_confirmed', { billing_period_end });
            break;
    }
});

// Setup complete
app.post('/api/setup/complete', async (req, res) => {
    await db.query('UPDATE users SET setup_completed_at = NOW() WHERE id = $1', [req.user.id]);
    await sendEmail(req.user.id, 'setup_complete', { firm_name, ai_phone_number, forwarding_number });
});
*/
