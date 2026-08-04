export interface AuthPrincipal {
  account_id: string;
  subject: string;
}

interface AuthUserResponse {
  id?: unknown;
}

interface AuthResponse {
  account_id?: unknown;
  subject?: unknown;
  user?: unknown;
}

function isAuthResponse(value: unknown): value is AuthResponse {
  return typeof value === "object" && value !== null;
}

function validIdentifier(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256;
}

function principalFromResponse(value: AuthResponse): AuthPrincipal | null {
  // The adapter response is kept for deployments that already expose the
  // relay identity contract directly.
  if (validIdentifier(value.account_id) && validIdentifier(value.subject)) {
    return { account_id: value.account_id, subject: value.subject };
  }

  // The canonical Dayflow account service returns the authenticated user from
  // GET /v1/me. The relay only needs the stable user ID; it does not persist
  // the rest of the account response.
  if (typeof value.user !== "object" || value.user === null) {
    return null;
  }
  const user = value.user as AuthUserResponse;
  if (!validIdentifier(user.id)) {
    return null;
  }
  return { account_id: user.id, subject: user.id };
}

/**
 * The relay never interprets a browser/session token itself. The binding is the
 * existing Dayflow account/auth service; it returns only the account identity
 * needed to select an account Durable Object.
 */
export async function authenticateRequest(
  request: Request,
  authService: Fetcher,
): Promise<AuthPrincipal | null> {
  const authorization = request.headers.get("Authorization");
  if (authorization === null || authorization.trim().length === 0) {
    return null;
  }

  const identityURL = new URL(request.url);
  identityURL.pathname = "/v1/me";
  identityURL.search = "";
  const authRequest = new Request(identityURL, {
    method: "GET",
    headers: {
      Authorization: authorization,
      "X-Dayflow-Auth-Purpose": "sync-relay",
    },
  });
  const response = await authService.fetch(authRequest);
  if (!response.ok) {
    return null;
  }

  let body: unknown;
  try {
    body = await response.json();
  } catch {
    return null;
  }

  if (!isAuthResponse(body)) {
    return null;
  }

  return principalFromResponse(body);
}
