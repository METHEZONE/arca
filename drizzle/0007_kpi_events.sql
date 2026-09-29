ALTER TYPE "public"."usage_kind" ADD VALUE 'realtime';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'chat_turn';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'recording_started';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'transcript_ready';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'action_plan_ready';--> statement-breakpoint
ALTER TYPE "public"."usage_kind" ADD VALUE 'execution_failed';