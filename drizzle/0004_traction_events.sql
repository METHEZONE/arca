ALTER TYPE "public"."usage_kind" ADD VALUE 'app_open';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'meeting_captured';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'proposal_shown';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'proposal_approved';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'proposal_rejected';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'task_tossed';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'loop_closed';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'auto_executed';--> statement-breakpoint
ALTER TABLE "usage_events" ADD COLUMN "owner" text;--> statement-breakpoint
CREATE INDEX "usage_events_owner_at_idx" ON "usage_events" USING btree ("owner","at");