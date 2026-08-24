-- ============================================================
-- STRUCTA — Schema Supabase
-- Execute no SQL Editor do seu projeto Supabase
-- ============================================================

-- 1. TABELA DE PERFIS (estende auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID        REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  email       TEXT        NOT NULL,
  nome        TEXT,
  role        TEXT        NOT NULL DEFAULT 'client' CHECK (role IN ('advisor', 'client')),
  slug        TEXT        UNIQUE, -- ex: 'luciana', 'dr_joao' (vincula ao ?c= da URL)
  advisor_id  UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. TABELA DE DADOS DO CLIENTE (armazena o objeto S inteiro como JSONB)
CREATE TABLE IF NOT EXISTS public.client_data (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  client_id   UUID        REFERENCES public.profiles(id) ON DELETE CASCADE UNIQUE NOT NULL,
  data        JSONB       NOT NULL DEFAULT '{}',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── ROW LEVEL SECURITY ──────────────────────────────────────────────────────

ALTER TABLE public.profiles   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_data ENABLE ROW LEVEL SECURITY;

-- profiles: cada user vê o próprio perfil
CREATE POLICY "Usuário vê o próprio perfil"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id);

-- profiles: advisor vê perfis dos seus clientes
CREATE POLICY "Advisor vê perfis dos clientes"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid() AND p.role = 'advisor'
    )
    AND advisor_id = auth.uid()
  );

-- profiles: usuário atualiza o próprio perfil
CREATE POLICY "Usuário atualiza o próprio perfil"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id);

-- client_data: cliente vê/edita apenas os próprios dados
CREATE POLICY "Cliente acessa os próprios dados"
  ON public.client_data FOR ALL
  USING (client_id = auth.uid());

-- client_data: advisor acessa dados dos seus clientes
CREATE POLICY "Advisor acessa dados dos clientes"
  ON public.client_data FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = auth.uid() AND p.role = 'advisor'
    )
    AND EXISTS (
      SELECT 1 FROM public.profiles cp
      WHERE cp.id = client_data.client_id AND cp.advisor_id = auth.uid()
    )
  );

-- ── FUNÇÕES E TRIGGERS ──────────────────────────────────────────────────────

-- Auto-cria perfil quando usuário se registra via magic link
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, nome)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'nome', split_part(NEW.email, '@', 1))
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Auto-atualiza updated_at
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER update_client_data_updated_at
  BEFORE UPDATE ON public.client_data
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

CREATE TRIGGER update_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ── DADOS INICIAIS ──────────────────────────────────────────────────────────
-- Execute APÓS criar sua conta no Supabase.
-- Substitua 'SEU_USER_ID_AQUI' pelo seu UID (em Auth > Users no painel).
-- UPDATE public.profiles SET role = 'advisor' WHERE id = 'SEU_USER_ID_AQUI';
