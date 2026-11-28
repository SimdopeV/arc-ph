// Supabase Edge Function: quiz-upload
// The host page sends the join code and PIN; this checks them (host_image_check,
// which counts wrong PINs towards the lockout) and returns a one-time link to
// upload one picture into the public quiz-images bucket under a random name.
//
// The service role key is never in this repo or the site: Supabase gives it to
// the function as the SUPABASE_SERVICE_ROLE_KEY setting.
// Deploy with JWT verification off (the site uses a publishable key, not a JWT);
// the PIN is the check.
import { createClient } from 'npm:@supabase/supabase-js@2.49.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const TYPES: Record<string, string> = { 'image/jpeg': 'jpg', 'image/webp': 'webp', 'image/png': 'png' };

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  let body: { code?: unknown; pin?: unknown; type?: unknown };
  try { body = await req.json(); } catch { return json({ error: 'bad_request' }, 400); }
  const code = String(body.code ?? '').slice(0, 20);
  const pin = String(body.pin ?? '').slice(0, 100);
  const ext = TYPES[String(body.type ?? 'image/jpeg')];
  if (!code || !pin) return json({ error: 'bad_pin' });
  if (!ext) return json({ error: 'bad_type' });

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const check = await admin.rpc('host_image_check', { p_code: code, p_pin: pin });
  if (check.error) return json({ error: 'server' }, 500);
  if (check.data?.error) return json({ error: check.data.error });

  const path = `${check.data.game}/${crypto.randomUUID()}.${ext}`;
  const up = await admin.storage.from('quiz-images').createSignedUploadUrl(path);
  if (up.error) return json({ error: 'storage' }, 500);
  return json({ path, token: up.data.token });
});
