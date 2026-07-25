"use client";

import type { Session } from "@supabase/supabase-js";
import { useEffect, useState } from "react";
import { supabaseBrowser } from "@/lib/supabaseBrowser";

type UserRow = {
  userId: string;
  email: string | null;
  signedUpAt: string;
  onlineAccess: boolean;
  accessGrantedAt: string | null;
  teamCount: number;
};

export default function Page() {
  const [session, setSession] = useState<Session | null>(null);
  const [checkingSession, setCheckingSession] = useState(true);
  const [email, setEmail] = useState("");
  const [linkSent, setLinkSent] = useState(false);
  const [authError, setAuthError] = useState<string | null>(null);
  const [users, setUsers] = useState<UserRow[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [busyUserId, setBusyUserId] = useState<string | null>(null);

  useEffect(() => {
    supabaseBrowser.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setCheckingSession(false);
    });
    const { data: sub } = supabaseBrowser.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (session) {
      loadUsers(session);
    } else {
      setUsers(null);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session]);

  async function loadUsers(activeSession: Session) {
    setLoadError(null);
    const res = await fetch("/api/users", {
      headers: { Authorization: `Bearer ${activeSession.access_token}` },
    });
    const body = await res.json();
    if (!res.ok) {
      setLoadError(body.error ?? "Failed to load signups.");
      return;
    }
    setUsers(body.users);
  }

  // A typed 6-digit code needs the "Magic Link" email template customized to print
  // {{ .Token }}, which isn't guaranteed to be editable/configured on every plan. A link-click
  // sign-in needs none of that -- it's Supabase's own default template, and supabase-js
  // auto-detects the resulting session from the URL once the click lands back on this page.
  async function sendMagicLink() {
    setAuthError(null);
    const { error } = await supabaseBrowser.auth.signInWithOtp({
      email,
      options: { shouldCreateUser: false, emailRedirectTo: window.location.origin },
    });
    if (error) {
      setAuthError(error.message);
      return;
    }
    setLinkSent(true);
  }

  async function signOut() {
    await supabaseBrowser.auth.signOut();
  }

  async function toggleAccess(row: UserRow) {
    if (!session) return;
    setBusyUserId(row.userId);
    const res = await fetch("/api/access", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${session.access_token}`,
      },
      body: JSON.stringify({ userId: row.userId, onlineAccess: !row.onlineAccess }),
    });
    const body = await res.json();
    setBusyUserId(null);
    if (!res.ok) {
      setLoadError(body.error ?? "Failed to update access.");
      return;
    }
    await loadUsers(session);
  }

  if (checkingSession) {
    return (
      <main className="page">
        <p>Loading…</p>
      </main>
    );
  }

  if (!session) {
    return (
      <main className="page">
        <h1>Claude Code Switcher — Admin</h1>
        {!linkSent ? (
          <div className="card">
            <p>Sign in with the admin account&apos;s email.</p>
            <input
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@example.com"
              autoComplete="email"
            />
            <button onClick={sendMagicLink} disabled={!email}>
              Send sign-in link
            </button>
          </div>
        ) : (
          <div className="card">
            <p>
              Check {email} and click the sign-in link -- it&apos;ll bring you right back here,
              signed in. No code to type.
            </p>
          </div>
        )}
        {authError && <p className="error">{authError}</p>}
      </main>
    );
  }

  return (
    <main className="page">
      <div className="header">
        <h1>Signups &amp; online access</h1>
        <button className="secondary" onClick={signOut}>
          Sign out
        </button>
      </div>
      {loadError && <p className="error">{loadError}</p>}
      {!users ? (
        <p>Loading…</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Email</th>
              <th>Signed up</th>
              <th>Teams joined</th>
              <th>Online access</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {users.map((row) => (
              <tr key={row.userId}>
                <td>{row.email ?? row.userId}</td>
                <td>{new Date(row.signedUpAt).toLocaleString()}</td>
                <td>{row.teamCount}</td>
                <td>{row.onlineAccess ? "Granted" : "Not granted"}</td>
                <td>
                  <button
                    className={row.onlineAccess ? "secondary" : undefined}
                    disabled={busyUserId === row.userId}
                    onClick={() => toggleAccess(row)}
                  >
                    {row.onlineAccess ? "Revoke" : "Grant"}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </main>
  );
}
