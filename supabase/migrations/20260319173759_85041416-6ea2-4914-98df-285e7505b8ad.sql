
-- Enum for user roles
CREATE TYPE public.app_role AS ENUM ('admin', 'moderator', 'user');

-- User roles table
CREATE TABLE public.user_roles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role app_role NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, role)
);
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Security definer function to check roles
CREATE OR REPLACE FUNCTION public.has_role(_user_id UUID, _role app_role)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles WHERE user_id = _user_id AND role = _role
  )
$$;

-- RLS: users can read their own roles, admins can read all
CREATE POLICY "Users can read own roles" ON public.user_roles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_role(auth.uid(), 'admin'));

-- Products table
CREATE TABLE public.products (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  description TEXT,
  price NUMERIC(10,2) NOT NULL,
  credits_per_use INTEGER NOT NULL DEFAULT 1000,
  total_limit INTEGER,
  daily_limit INTEGER,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Products are publicly readable" ON public.products FOR SELECT USING (true);
CREATE POLICY "Admins can manage products" ON public.products FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Tokens table
CREATE TABLE public.tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token TEXT NOT NULL DEFAULT encode(gen_random_bytes(16), 'hex') UNIQUE,
  client_name TEXT NOT NULL,
  total_limit INTEGER,
  daily_limit INTEGER DEFAULT 5000,
  credits_per_use INTEGER NOT NULL DEFAULT 1000,
  expires_at TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_by UUID REFERENCES auth.users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins can manage tokens" ON public.tokens FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Service role full access tokens" ON public.tokens FOR ALL USING (true);

-- Token accounts (links auth users to tokens)
CREATE TABLE public.token_accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token_id UUID REFERENCES public.tokens(id) ON DELETE CASCADE NOT NULL,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  email TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(token_id)
);
ALTER TABLE public.token_accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own token accounts" ON public.token_accounts FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Service role full access token_accounts" ON public.token_accounts FOR ALL USING (true);

-- Wallets table
CREATE TABLE public.wallets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL UNIQUE,
  balance NUMERIC(12,2) NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own wallet" ON public.wallets FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Admins can read all wallets" ON public.wallets FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Enable realtime for wallets
ALTER PUBLICATION supabase_realtime ADD TABLE public.wallets;

-- Wallet transactions table
CREATE TABLE public.wallet_transactions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id UUID REFERENCES public.wallets(id) ON DELETE CASCADE NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('deposit', 'debit')),
  amount NUMERIC(12,2) NOT NULL,
  credits INTEGER,
  description TEXT,
  reference_id TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own transactions" ON public.wallet_transactions FOR SELECT TO authenticated
  USING (wallet_id IN (SELECT id FROM public.wallets WHERE user_id = auth.uid()));
CREATE POLICY "Admins can read all transactions" ON public.wallet_transactions FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(), 'admin'));

-- Orders table
CREATE TABLE public.orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id UUID REFERENCES public.products(id),
  amount NUMERIC(10,2) NOT NULL,
  customer_name TEXT,
  customer_email TEXT,
  customer_document TEXT,
  transaction_id TEXT,
  pix_code TEXT,
  pix_expires_at TEXT,
  status TEXT NOT NULL DEFAULT 'pending',
  paid_at TIMESTAMPTZ,
  order_type TEXT DEFAULT 'token',
  token_id UUID REFERENCES public.tokens(id),
  upgrade_increment INTEGER,
  user_id UUID REFERENCES auth.users(id),
  coupon_id UUID,
  discount_amount NUMERIC(10,2) DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own orders" ON public.orders FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Admins can manage orders" ON public.orders FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Service role full access orders" ON public.orders FOR ALL USING (true);

-- Generations table
CREATE TABLE public.generations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  farm_id TEXT NOT NULL,
  token_id UUID REFERENCES public.tokens(id),
  user_id UUID REFERENCES auth.users(id),
  client_name TEXT NOT NULL DEFAULT 'unknown',
  credits_requested INTEGER NOT NULL DEFAULT 0,
  credits_earned INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'creating',
  master_email TEXT,
  workspace_name TEXT,
  error_message TEXT,
  client_ip TEXT,
  settled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.generations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated can read generations" ON public.generations FOR SELECT TO authenticated USING (true);
CREATE POLICY "Admins can manage generations" ON public.generations FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE POLICY "Service role full access generations" ON public.generations FOR ALL USING (true);

-- Enable realtime for generations
ALTER PUBLICATION supabase_realtime ADD TABLE public.generations;

-- Client tokens (reseller links)
CREATE TABLE public.client_tokens (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  token TEXT NOT NULL DEFAULT encode(gen_random_bytes(16), 'hex') UNIQUE,
  owner_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  total_credits INTEGER NOT NULL DEFAULT 0,
  credits_used INTEGER NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.client_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can read own client tokens" ON public.client_tokens FOR SELECT TO authenticated USING (owner_id = auth.uid());
CREATE POLICY "Service role full access client_tokens" ON public.client_tokens FOR ALL USING (true);

-- Coupons table
CREATE TABLE public.coupons (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT NOT NULL UNIQUE,
  discount_type TEXT NOT NULL CHECK (discount_type IN ('percentage', 'fixed')),
  discount_value NUMERIC(10,2) NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  expires_at TIMESTAMPTZ,
  max_uses INTEGER,
  times_used INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.coupons ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Coupons readable by all" ON public.coupons FOR SELECT USING (true);
CREATE POLICY "Admins can manage coupons" ON public.coupons FOR ALL TO authenticated USING (public.has_role(auth.uid(), 'admin'));

-- Rate limiting table
CREATE TABLE public.rate_limits (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID,
  ip TEXT,
  endpoint TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;

-- Banned users table
CREATE TABLE public.banned_users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL UNIQUE,
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.banned_users ENABLE ROW LEVEL SECURITY;

-- Banned IPs table
CREATE TABLE public.banned_ips (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ip TEXT NOT NULL UNIQUE,
  reason TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.banned_ips ENABLE ROW LEVEL SECURITY;

-- Function: debit_wallet
CREATE OR REPLACE FUNCTION public.debit_wallet(
  p_user_id UUID,
  p_amount NUMERIC,
  p_credits INTEGER DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_reference_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id UUID;
  v_balance NUMERIC;
  v_new_balance NUMERIC;
BEGIN
  -- Get wallet with lock
  SELECT id, balance INTO v_wallet_id, v_balance
  FROM public.wallets
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_wallet_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Carteira não encontrada');
  END IF;

  IF v_balance < p_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'Saldo insuficiente', 'balance', v_balance, 'required', p_amount);
  END IF;

  v_new_balance := v_balance - p_amount;

  UPDATE public.wallets SET balance = v_new_balance, updated_at = now() WHERE id = v_wallet_id;

  INSERT INTO public.wallet_transactions (wallet_id, type, amount, credits, description, reference_id)
  VALUES (v_wallet_id, 'debit', p_amount, p_credits, p_description, p_reference_id);

  RETURN jsonb_build_object('success', true, 'new_balance', v_new_balance);
END;
$$;

-- Function: credit_wallet
CREATE OR REPLACE FUNCTION public.credit_wallet(
  p_user_id UUID,
  p_amount NUMERIC,
  p_description TEXT DEFAULT NULL,
  p_reference_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet_id UUID;
  v_new_balance NUMERIC;
  v_existing BOOLEAN;
BEGIN
  -- Check for duplicate credit by reference_id
  IF p_reference_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM public.wallet_transactions
      WHERE reference_id = p_reference_id AND type = 'deposit'
    ) INTO v_existing;
    IF v_existing THEN
      RETURN jsonb_build_object('success', true, 'already_credited', true);
    END IF;
  END IF;

  -- Get or create wallet
  SELECT id INTO v_wallet_id FROM public.wallets WHERE user_id = p_user_id FOR UPDATE;

  IF v_wallet_id IS NULL THEN
    INSERT INTO public.wallets (user_id, balance) VALUES (p_user_id, p_amount)
    RETURNING id INTO v_wallet_id;
    v_new_balance := p_amount;
  ELSE
    UPDATE public.wallets SET balance = balance + p_amount, updated_at = now() WHERE id = v_wallet_id
    RETURNING balance INTO v_new_balance;
  END IF;

  INSERT INTO public.wallet_transactions (wallet_id, type, amount, description, reference_id)
  VALUES (v_wallet_id, 'deposit', p_amount, p_description, p_reference_id);

  RETURN jsonb_build_object('success', true, 'new_balance', v_new_balance);
END;
$$;

-- Function: is_user_banned
CREATE OR REPLACE FUNCTION public.is_user_banned(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.banned_users WHERE user_id = p_user_id)
$$;

-- Function: is_ip_banned
CREATE OR REPLACE FUNCTION public.is_ip_banned(p_ip TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (SELECT 1 FROM public.banned_ips WHERE ip = p_ip)
$$;

-- Function: check_rate_limit
CREATE OR REPLACE FUNCTION public.check_rate_limit(
  p_user_id UUID,
  p_ip TEXT,
  p_endpoint TEXT,
  p_max_requests INTEGER,
  p_window_seconds INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER;
  v_window TIMESTAMPTZ;
BEGIN
  v_window := now() - (p_window_seconds || ' seconds')::INTERVAL;

  SELECT COUNT(*) INTO v_count
  FROM public.rate_limits
  WHERE (user_id = p_user_id OR ip = p_ip)
    AND endpoint = p_endpoint
    AND created_at > v_window;

  -- Record this request
  INSERT INTO public.rate_limits (user_id, ip, endpoint) VALUES (p_user_id, p_ip, p_endpoint);

  -- Clean old entries
  DELETE FROM public.rate_limits WHERE created_at < v_window AND endpoint = p_endpoint;

  IF v_count >= p_max_requests THEN
    RETURN jsonb_build_object('allowed', false, 'count', v_count);
  END IF;

  RETURN jsonb_build_object('allowed', true, 'count', v_count);
END;
$$;

-- Function: increment_coupon_usage
CREATE OR REPLACE FUNCTION public.increment_coupon_usage(p_coupon_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.coupons SET times_used = times_used + 1 WHERE id = p_coupon_id;
END;
$$;
