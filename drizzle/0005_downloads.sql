CREATE TABLE "downloads" (
	"id" bigserial PRIMARY KEY NOT NULL,
	"at" timestamp with time zone DEFAULT now() NOT NULL,
	"target" text NOT NULL,
	"url" text NOT NULL,
	"email" text,
	"user_id" uuid,
	"device_id" text,
	"source" text,
	"referer" text,
	"user_agent" text,
	"ip_hash" text,
	"country" text,
	"region" text,
	"city" text
);
--> statement-breakpoint
ALTER TABLE "downloads" ADD CONSTRAINT "downloads_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "downloads_at_idx" ON "downloads" USING btree ("at");--> statement-breakpoint
CREATE INDEX "downloads_email_idx" ON "downloads" USING btree ("email");