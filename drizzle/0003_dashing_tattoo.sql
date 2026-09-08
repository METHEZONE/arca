CREATE TABLE "memory_entries" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"owner" text NOT NULL,
	"text" text NOT NULL,
	"kind" text DEFAULT 'fact' NOT NULL,
	"source" text DEFAULT 'chat' NOT NULL,
	"source_ref" text,
	"device_id" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"consolidated_at" timestamp with time zone,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "memory_pages" (
	"owner" text NOT NULL,
	"slug" text NOT NULL,
	"title" text NOT NULL,
	"summary" text NOT NULL,
	"body" text NOT NULL,
	"edges" text[] DEFAULT '{}' NOT NULL,
	"origin_date" timestamp with time zone,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "memory_pages_owner_slug_pk" PRIMARY KEY("owner","slug")
);
--> statement-breakpoint
CREATE TABLE "memory_runs" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"owner" text NOT NULL,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"finished_at" timestamp with time zone,
	"entries_count" integer DEFAULT 0 NOT NULL,
	"pages_written" integer DEFAULT 0 NOT NULL,
	"ok" boolean DEFAULT false NOT NULL,
	"error" text
);
--> statement-breakpoint
CREATE TABLE "memory_views" (
	"owner" text NOT NULL,
	"name" text NOT NULL,
	"body" text NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "memory_views_owner_name_pk" PRIMARY KEY("owner","name")
);
--> statement-breakpoint
CREATE INDEX "memory_entries_owner_created_idx" ON "memory_entries" USING btree ("owner","created_at");--> statement-breakpoint
CREATE INDEX "memory_entries_owner_consolidated_idx" ON "memory_entries" USING btree ("owner","consolidated_at");