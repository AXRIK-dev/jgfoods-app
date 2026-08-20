-- ============================================================
-- Migration 049: Log what Jon asks the Help tab
-- JG Foods Admin App
-- ============================================================
-- WHY
--
-- The Help tab will absorb most of the questions Jon currently sends Phil by
-- WhatsApp. Good for Jon — but it also means Phil stops SEEING what Jon
-- struggles with, and the pattern is the useful part.
--
-- One question asked once is a question. The same question asked five times
-- over three weeks is a screen that needs changing. Answering it again in the
-- guide just means answering it again next month.
--
-- Exactly that happened on 19 Aug: Jon couldn't log a Friday order, we
-- explained it, and the real fix turned out to be a line of text on the Log
-- Order screen pointing at Schedule. The question stops happening rather than
-- getting answered repeatedly.
--
-- The ones the AI COULDN'T answer are the feature requests — written down in
-- Jon's own words without him having to raise them.
--
-- Run AFTER 048. Adds one table. Touches nothing existing.
-- ============================================================

CREATE TABLE IF NOT EXISTS support_questions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asked_at     timestamptz NOT NULL DEFAULT now(),
  question     text NOT NULL,
  -- true  = the guide covered it
  -- false = the app genuinely can't do it (a feature request)
  -- null  = the AI was unreachable and the keyword fallback ran
  could_answer boolean,
  page         text,               -- which admin page the answer pointed at
  asked_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE support_questions IS
  'Every question typed into the Help tab. Read it for repeated questions: '
  'those are screens to fix, not wording to reword.';

CREATE INDEX IF NOT EXISTS idx_support_questions_asked_at
  ON support_questions (asked_at DESC);


-- ── Security ──────────────────────────────────────────────────
-- Staff only. Questions can contain customer names, so this is not public.
ALTER TABLE support_questions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "staff can log a question"    ON support_questions;
DROP POLICY IF EXISTS "admin can read questions"    ON support_questions;
DROP POLICY IF EXISTS "admin can clear questions"   ON support_questions;

-- Anyone signed in can record what they asked — including a driver, whose
-- confusion is worth seeing too.
CREATE POLICY "staff can log a question"
  ON support_questions FOR INSERT TO authenticated
  WITH CHECK (true);

CREATE POLICY "admin can read questions"
  ON support_questions FOR SELECT TO authenticated
  USING (public.current_user_role() = 'admin');

CREATE POLICY "admin can clear questions"
  ON support_questions FOR DELETE TO authenticated
  USING (public.current_user_role() = 'admin');


-- ============================================================
-- WHAT TO LOOK AT
--
--   -- Most-asked, and whether the app could answer:
--   SELECT lower(btrim(question)) AS asked,
--          count(*)               AS times,
--          bool_and(could_answer) AS always_answered,
--          max(asked_at)::date    AS last_asked
--   FROM support_questions
--   GROUP BY 1
--   ORDER BY times DESC, last_asked DESC
--   LIMIT 30;
--
--   -- The feature requests, in Jon's own words:
--   SELECT asked_at::date, question
--   FROM support_questions
--   WHERE could_answer IS FALSE
--   ORDER BY asked_at DESC;
--
-- The same list is on the Help page in the app, under "Questions asked".
--
--
-- NOTES FOR PHIL
--
-- * Give it a week or two before reading much into it. The first few days
--   will be "where is everything", which tells you little. The REPEAT
--   questions after he's settled in are the signal.
--
-- * Reusable for other AXRIK clients: ship the support tab and this table
--   together. It turns support load into a prioritised list of what to fix,
--   written by the person actually using the thing.
-- ============================================================
