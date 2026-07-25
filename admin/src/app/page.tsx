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
  const [code, setCode] = useState("");
  const [awaitingCode, setAwaitingCode] = useState(false);
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

  async function sendCode() {
    setAuthError(null);
    const { error } = await supabaseBrowser.auth.signInWithOtp({
      email,
      options: { shouldCreateUser: false },
    });
    if (error) {
      setAuthError(error.message);
      return;
    }
    setAwaitingCode(true);
  }

  async function verifyCode() {
    setAuthError(null);
    const { error } = await supabaseBrowser.auth.verifyOtp({ email, token: code, type: "email" });
    if (error) {
      setAuthError(error.message);
    }
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
        {!awaitingCode ? (
          <div className="card">
            <p>Sign in with the admin account&apos;s email.</p>
            <input
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="you@example.com"
              autoComplete="email"
            />
            <button onClick={sendCode} disabled={!email}>
              Send code
            </button>
          </div>
        ) : (
          <div className="card">
            <p>Enter the 6-digit code sent to {email}.</p>
            <input
              value={code}
              onChange={(e) => setCode(e.target.value)}
              placeholder="123456"
              inputMode="numeric"
            />
            <button onClick={verifyCode} disabled={code.length < 6}>
              Verify
            </button>
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
