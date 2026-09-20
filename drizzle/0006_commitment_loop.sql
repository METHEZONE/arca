CREATE TYPE "public"."commitment_status" AS ENUM('detected', 'proposed', 'accepted', 'authorized', 'in_progress', 'evidence_submitted', 'verified');--> statement-breakpoint
CREATE TABLE "commitment_nodes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"commitment_id" uuid NOT NULL,
	"position" integer NOT NULL,
	"title" text NOT NULL,
	"kind" text NOT NULL,
	"risky" boolean DEFAULT false NOT NULL,
	"question" text,
	"status" text DEFAULT 'pending' NOT NULL,
	"artifact" text,
	"evidence" text,
	"evidence_kind" text,
	"evidence_at" timestamp with time zone,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "commitments" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"title" text NOT NULL,
	"counterpart" text,
	"due" text,
	"outcome" text NOT NULL,
	"source_quote" text,
	"source_kind" text DEFAULT 'text' NOT NULL,
	"source_summary" text,
	"source_transcript" text,
	"status" "commitment_status" DEFAULT 'detected' NOT NULL,
	"scope_start" integer,
	"scope_end" integer,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "feedback_events" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"at" timestamp with time zone DEFAULT now() NOT NULL,
	"user_id" uuid NOT NULL,
	"commitment_id" uuid,
	"node_id" uuid,
	"rail" text NOT NULL,
	"value" text NOT NULL,
	"note" text
);
--> statement-breakpoint
CREATE TABLE "profiles" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"display_name" text,
	"headline" text,
	"company" text,
	"company_url" text,
	"avatar_url" text,
	"sources" jsonb DEFAULT '[]'::jsonb NOT NULL,
	"confirmed_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "commitment_nodes" ADD CONSTRAINT "commitment_nodes_commitment_id_commitments_id_fk" FOREIGN KEY ("commitment_id") REFERENCES "public"."commitments"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "commitments" ADD CONSTRAINT "commitments_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "feedback_events" ADD CONSTRAINT "feedback_events_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "feedback_events" ADD CONSTRAINT "feedback_events_commitment_id_commitments_id_fk" FOREIGN KEY ("commitment_id") REFERENCES "public"."commitments"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "feedback_events" ADD CONSTRAINT "feedback_events_node_id_commitment_nodes_id_fk" FOREIGN KEY ("node_id") REFERENCES "public"."commitment_nodes"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "profiles" ADD CONSTRAINT "profiles_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "commitment_nodes_commitment_idx" ON "commitment_nodes" USING btree ("commitment_id","position");--> statement-breakpoint
CREATE INDEX "commitments_user_created_idx" ON "commitments" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "feedback_events_user_at_idx" ON "feedback_events" USING btree ("user_id","at");