-- ============================================================
-- STRUCTA — Schema Supabase
-- Execute no SQL Editor do seu projeto Supabase
--
-- Perfis:
--   master   → você (gestaojanainamachado@gmail.com). Acesso total: monta e
--              edita o dashboard de qualquer cliente, de qualquer consultor,
--              e convida novos consultores. Atribuído automaticamente no
--              primeiro login (ver handle_new_user / self-heal no app).
--   advisor  → "Consultor" na interface. Cria e edita os próprios clientes,
--              convida clientes, só enxerga o que é seu.
--   client   → acesso somente ao que foi liberado (Lançamentos para editar;
--              Orçamento e Objetivos só para visualizar).
-- ============================================================

-- 1. TABELA DE PERFIS (estende auth.users)
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID        REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  email       TEXT        NOT NULL,
  nome        TEXT,
  role        TEXT        NOT NULL DEFAULT 'client' CHECK (role IN ('master', 'advisor', 'client')),
  slug        TEXT        UNIQUE, -- ex: 'luciana', 'dr_joao' (vincula ao ?c= da URL) — só para clientes
  advisor_id  UUID        REFERENCES public.profiles(id) ON DELETE SET NULL, -- quem é o consultor deste cliente
  password_set BOOLEAN    NOT NULL DEFAULT false, -- já criou a própria senha? (ver sbRenderForcePasswordScreen no app)
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Se a tabela já existia (schema anterior sem o papel 'master' e/ou sem
-- password_set), rode isto antes do resto do script:
--   ALTER TABLE public.profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
--   ALTER TABLE public.profiles ADD CONSTRAINT profiles_role_check CHECK (role IN ('master','advisor','client'));
--   ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS password_set BOOLEAN NOT NULL DEFAULT false;
--   -- Backfill: quem já tinha criado senha antes (fluxo antigo, opcional) não
--   -- precisa passar pela tela obrigatória de novo.
--   UPDATE public.profiles p SET password_set = true
--     FROM auth.users u
--     WHERE u.id = p.id AND u.encrypted_password IS NOT NULL AND u.encrypted_password <> '';

-- 2. TABELA DE DADOS DO CLIENTE (armazena o objeto S inteiro como JSONB)
-- Observação: o app identifica o workspace do cliente pelo "slug" (não pelo
-- profiles.id), para suportar workspaces criados localmente antes de o
-- cliente ter conta — por isso client_data é indexada por slug.
CREATE TABLE IF NOT EXISTS public.client_data (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  slug        TEXT        UNIQUE NOT NULL,
  advisor_id  UUID        REFERENCES public.profiles(id) ON DELETE SET NULL,
  data        JSONB       NOT NULL DEFAULT '{}',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3. CONVITES PENDENTES — criados pelo consultor/master ANTES de o convidado
-- ter conta; quando a pessoa faz login pela primeira vez (magic link/OTP), o
-- app lê esta tabela por e-mail e ativa o perfil certo (cliente com slug, ou
-- novo consultor).
CREATE TABLE IF NOT EXISTS public.pending_invites (
  id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  email       TEXT        UNIQUE NOT NULL,
  invite_role TEXT        NOT NULL DEFAULT 'client' CHECK (invite_role IN ('advisor', 'client')),
  advisor_id  UUID        REFERENCES public.profiles(id) ON DELETE SET NULL, -- quem convidou (dono do cliente)
  slug        TEXT,       -- obrigatório na prática para convite de cliente; nulo para convite de consultor
  name        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── ROW LEVEL SECURITY ──────────────────────────────────────────────────────

ALTER TABLE public.profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.client_data    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pending_invites ENABLE ROW LEVEL SECURITY;

-- Helper (via subquery nas policies abaixo): "sou master" = existe profiles
-- com meu id e role='master'.

-- profiles: cada usuário vê o próprio perfil
CREATE POLICY "Usuário vê o próprio perfil"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id);

-- profiles: consultor vê perfis dos seus clientes
CREATE POLICY "Consultor vê perfis dos clientes"
  ON public.profiles FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'advisor')
    AND advisor_id = auth.uid()
  );

-- profiles: master vê e gerencia todos os perfis (consultores e clientes)
CREATE POLICY "Master vê todos os perfis"
  ON public.profiles FOR SELECT
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'master'));

CREATE POLICY "Master atualiza qualquer perfil"
  ON public.profiles FOR UPDATE
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'master'));

CREATE POLICY "Master apaga qualquer perfil"
  ON public.profiles FOR DELETE
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'master'));

-- profiles: usuário atualiza o próprio perfil
CREATE POLICY "Usuário atualiza o próprio perfil"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id);

-- profiles: consultor apaga perfis dos próprios clientes (ex: ao excluir cliente)
CREATE POLICY "Consultor apaga perfis dos clientes"
  ON public.profiles FOR DELETE
  USING (
    EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'advisor')
    AND advisor_id = auth.uid()
  );

-- client_data: cliente acessa os próprios dados (via profiles.slug == client_data.slug)
CREATE POLICY "Cliente acessa os próprios dados"
  ON public.client_data FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.slug = client_data.slug)
  );

-- client_data: consultor acessa dados dos seus clientes
CREATE POLICY "Consultor acessa dados dos clientes"
  ON public.client_data FOR ALL
  USING (
    EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'advisor')
    AND advisor_id = auth.uid()
  );

-- client_data: master acessa (lê/edita/apaga) os dados de QUALQUER cliente,
-- de qualquer consultor — é o que dá a ela autonomia total sobre o sistema.
CREATE POLICY "Master acessa todos os dados"
  ON public.client_data FOR ALL
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'master'));

-- pending_invites: consultor/master vê e cria convites que ele mesmo emitiu
CREATE POLICY "Convite visível para quem convidou"
  ON public.pending_invites FOR SELECT
  USING (advisor_id = auth.uid() OR advisor_id IS NULL);

CREATE POLICY "Consultor/master cria convites"
  ON public.pending_invites FOR INSERT
  WITH CHECK (
    EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role IN ('advisor', 'master'))
  );

-- pending_invites: o próprio convidado lê (e depois apaga) seu convite ao
-- logar pela primeira vez, para o app poder ativar o perfil certo
CREATE POLICY "Convidado vê o próprio convite"
  ON public.pending_invites FOR SELECT
  USING (email = auth.email());

CREATE POLICY "Convidado apaga o próprio convite após ativar"
  ON public.pending_invites FOR DELETE
  USING (email = auth.email());

-- pending_invites: master apaga qualquer convite
CREATE POLICY "Master apaga qualquer convite"
  ON public.pending_invites FOR DELETE
  USING (EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'master'));

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
-- O e-mail master (gestaojanainamachado@gmail.com) vira role='master' sozinho
-- no primeiro login — não precisa rodar nada aqui para isso (self-heal no
-- app, em sbLoadData). Caso queira promover alguém manualmente a consultor:
-- UPDATE public.profiles SET role = 'advisor' WHERE id = 'ID_DO_CONSULTOR';
