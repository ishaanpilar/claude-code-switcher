"use client";

import { createClient } from "@supabase/supabase-js";
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "./supabaseConfig";

/** Anon-key client for the login form only. Every real read/write goes through the API routes. */
export const supabaseBrowser = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
