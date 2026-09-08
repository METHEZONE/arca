ALTER TABLE "organizations" ADD COLUMN "digest_sent_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "digest_opt_out" boolean DEFAULT false NOT NULL;