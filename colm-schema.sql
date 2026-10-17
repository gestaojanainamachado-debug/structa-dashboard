-- ============================================================
-- COLM — Sistema de Controle da Secretaria (Clínica de Olhos Lopes da Motta)
-- Execute no mesmo projeto Supabase usado pelo Structa (SQL Editor).
-- Tabelas isoladas (prefixo colm_), não interferem no schema.sql do Structa.
--
-- Acesso: qualquer usuário autenticado no projeto (auth.users) pode ler e
-- gravar. Crie o login da secretária em Authentication → Users → Add user
-- (e-mail + senha), ou peça para ela se cadastrar pela tela de login da
-- página colm.html (signUp). Não há papéis/permissões diferentes aqui —
-- é um sistema interno de uso único pela secretaria/gestão da clínica.
-- ============================================================

-- 1. TABELAS DE REFERÊNCIA (equivalentes a BASE GERAL / BASEPROCEDIMENTO) ---

CREATE TABLE IF NOT EXISTS public.colm_convenios (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome        TEXT UNIQUE NOT NULL,
  imposto     NUMERIC NOT NULL DEFAULT 0,      -- fração, ex: 0.17 = 17%
  dias_pgto   INTEGER NOT NULL DEFAULT 0,      -- prazo de recebimento em dias
  ativo       BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.colm_formas_pagamento (
  id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome   TEXT UNIQUE NOT NULL,
  taxa   NUMERIC NOT NULL DEFAULT 0,           -- taxa de cartão, fração
  ativo  BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.colm_instituicoes (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome                TEXT UNIQUE NOT NULL,
  retencao_consulta   NUMERIC NOT NULL DEFAULT 0,
  retencao_cirurgia   NUMERIC NOT NULL DEFAULT 0,
  retencao_aplicacao  NUMERIC NOT NULL DEFAULT 0,
  ativo               BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.colm_medicos (
  id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome   TEXT UNIQUE NOT NULL,
  ativo  BOOLEAN NOT NULL DEFAULT true
);

-- procedimento x convênio → valor bruto (tabela de preços)
CREATE TABLE IF NOT EXISTS public.colm_procedimentos (
  id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nome    TEXT UNIQUE NOT NULL,
  precos  JSONB NOT NULL DEFAULT '{}',  -- { "UNIMED PF": 2071, "PARTICULAR": 3500, ... }
  ativo   BOOLEAN NOT NULL DEFAULT true
);

-- 2. LANÇAMENTOS DE APLICAÇÃO (equivalente à aba "APLICAÇÃO COLM/RM") ------

CREATE TABLE IF NOT EXISTS public.colm_lancamentos (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by                UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  data                      DATE NOT NULL,
  paciente                  TEXT NOT NULL,
  convenio                  TEXT NOT NULL,
  procedimento              TEXT NOT NULL,
  olho                      TEXT,                 -- 'OD' | 'OE' | 'AO'
  instituicao               TEXT NOT NULL DEFAULT 'COLM',  -- 'COLM' | 'RM'
  medico                    TEXT NOT NULL,
  forma_pagamento           TEXT NOT NULL,
  medicamento_do_plano      NUMERIC,              -- valor do medicamento quando fornecido pelo plano

  -- entradas manuais
  desconto_acrescimo        NUMERIC NOT NULL DEFAULT 0,
  deflator                  NUMERIC NOT NULL DEFAULT 0,
  taxa_sala                 NUMERIC NOT NULL DEFAULT 0,   -- normalmente negativo
  instrumental              NUMERIC NOT NULL DEFAULT 0,   -- normalmente negativo
  custo_dose_remedio        NUMERIC NOT NULL DEFAULT 0,   -- normalmente negativo

  -- calculados no app no momento de salvar (ver fórmulas em colm.html)
  valor_bruto               NUMERIC NOT NULL DEFAULT 0,
  valor_apos_desc_acresc    NUMERIC NOT NULL DEFAULT 0,
  impostos                  NUMERIC NOT NULL DEFAULT 0,
  taxa_cartao               NUMERIC NOT NULL DEFAULT 0,
  valor_liquido             NUMERIC NOT NULL DEFAULT 0,
  dif_medicamento           NUMERIC NOT NULL DEFAULT 0,
  valor_liquido_final       NUMERIC NOT NULL DEFAULT 0,
  retencao_clinica          NUMERIC NOT NULL DEFAULT 0,
  comissao_secretaria       NUMERIC NOT NULL DEFAULT 0,
  recebimento_medico        NUMERIC NOT NULL DEFAULT 0,
  pct_medico                NUMERIC,

  -- controle / recebimento
  guia                      TEXT,
  nf                        TEXT,
  obs                       TEXT,
  data_prevista_recebimento DATE,
  data_real_recebimento     DATE,
  glosa                     NUMERIC NOT NULL DEFAULT 0,
  data_pgto_medico          DATE
);

CREATE INDEX IF NOT EXISTS colm_lanc_data_idx ON public.colm_lancamentos (data);
CREATE INDEX IF NOT EXISTS colm_lanc_medico_idx ON public.colm_lancamentos (medico);
CREATE INDEX IF NOT EXISTS colm_lanc_convenio_idx ON public.colm_lancamentos (convenio);
CREATE INDEX IF NOT EXISTS colm_lanc_recebimento_idx ON public.colm_lancamentos (data_real_recebimento);

CREATE OR REPLACE FUNCTION public.colm_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER colm_lancamentos_updated_at
  BEFORE UPDATE ON public.colm_lancamentos
  FOR EACH ROW EXECUTE FUNCTION public.colm_set_updated_at();

-- 3. RLS — qualquer usuário autenticado do projeto tem acesso total -------

ALTER TABLE public.colm_convenios        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.colm_formas_pagamento ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.colm_instituicoes     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.colm_medicos          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.colm_procedimentos    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.colm_lancamentos      ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['colm_convenios','colm_formas_pagamento','colm_instituicoes','colm_medicos','colm_procedimentos','colm_lancamentos']
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS "Autenticado acesso total" ON public.%I', t);
    EXECUTE format('CREATE POLICY "Autenticado acesso total" ON public.%I FOR ALL USING (auth.uid() IS NOT NULL) WITH CHECK (auth.uid() IS NOT NULL)', t);
  END LOOP;
END $$;

-- 4. DADOS INICIAIS (extraídos das abas BASE GERAL / BASEPROCEDIMENTO) ----

INSERT INTO public.colm_convenios (nome, imposto, dias_pgto) VALUES
  ('AME', 0.17, 60), ('AMIL', 0.1893, 60), ('AMIL RM', 0.1893, 60), ('ACJF', 0, 45),
  ('ACJF SUS', 0.17, 0), ('BRADESCO', 0.17, 60), ('CAIXA', 0.17, 60), ('CASSI', 0.17, 60),
  ('CEMIG', 0.17, 60), ('FUSEX', 0.17, 90), ('GNDI', 0.17, 60), ('HAPVIDA', 0.17, 60),
  ('MEDISERVICE', 0.17, 60), ('PARTICULAR', 0, 0), ('PARTICULAR COM NF', 0.17, 0),
  ('PARTICULAR RM', 0.1893, 60), ('PLASC', 0.17, 0), ('PM', 0.1893, 60),
  ('SABIN SINAI', 0.17, 150), ('SAUDE SERVIDOR', 0.17, 150), ('ESTADO', 0.17, 0),
  ('UNIMED PF', 0.275, 30), ('UNIMED PJ', 0.17, 90)
ON CONFLICT (nome) DO NOTHING;

INSERT INTO public.colm_formas_pagamento (nome, taxa) VALUES
  ('BOLETO', 0), ('CC AMEX PJ', 0.0282), ('CC ELO PARC PF', 0.0434),
  ('CC ELO PARC PJ 1-6x', 0.038), ('CC ELO PARC PJ 7-12x', 0.038), ('CC ELO PF', 0.0292),
  ('CC ELO PJ', 0.0288), ('CC VISA E MASTER PARC PF', 0.0317),
  ('CC VISA E MASTER PARC PJ 1-6x', 0.0326), ('CC VISA E MASTER PARC PJ 7-12x', 0.0365),
  ('CC VISA E MASTER PF', 0.025), ('CC VISA E MASTER PJ', 0.0273),
  ('CD ELO PF', 0.0244), ('CD ELO PJ', 0.0191), ('CD VISA E MASTER PF', 0.0178),
  ('CD VISA E MASTER PJ', 0.0199), ('DINHEIRO', 0), ('LIMINAR JUDICIAL', 0),
  ('PIX PF', 0), ('PIX PJ', 0), ('PL.SAUDE', 0), ('PROMISSORIA', 0),
  ('RM - 90', 0), ('SEM ONUS', 0), ('VC - 30', 0), ('VC - 90', 0)
ON CONFLICT (nome) DO NOTHING;

INSERT INTO public.colm_instituicoes (nome, retencao_consulta, retencao_cirurgia, retencao_aplicacao) VALUES
  ('ACJF', 0.25, 0, 0), ('COLM', 0.25, 0.205, 0.25), ('HOSPITAL UNIMED', 0.25, 0.205, 0.25),
  ('MONTE SINAI', 0.25, 0.205, 0.25), ('RM', 0.25, 0, 0), ('SANTA CASA', 0.25, 0.205, 0.25),
  ('SINAI LASER', 0.25, 0.205, 0.25), ('OLHAR', 0.25, 0.205, 0.25),
  ('VISION CENTER', 0.25, 0.205, 0.25), ('SUS', 0, 0, 0), ('S/C', 0, 0, 0)
ON CONFLICT (nome) DO NOTHING;

INSERT INTO public.colm_medicos (nome) VALUES
  ('AUGUSTO')
ON CONFLICT (nome) DO NOTHING;

INSERT INTO public.colm_procedimentos (nome, precos) VALUES
('IV AVASTIN', '{"AME":3500,"AMIL":3800,"AMIL RM":3800,"BRADESCO":3150,"CAIXA":5115.9,"CASSI":3982.69,"CEMIG":5438.82,"FUSEX":3160.52,"GNDI":3800,"MEDISERVICE":3150,"PARTICULAR":1800,"PARTICULAR COM NF":1800,"PARTICULAR RM":1800,"PLASC":3200,"PM":1861.42,"SABIN SINAI":5119.44,"SAUDE SERVIDOR":2071,"ESTADO":1800,"UNIMED PF":2071,"UNIMED PJ":2071}'),
('IV EYLIA 4mg', '{"AME":3500,"AMIL":3800,"AMIL RM":3800,"BRADESCO":3150,"CAIXA":5115.9,"CASSI":3982.69,"CEMIG":5438.82,"FUSEX":3160.52,"GNDI":3800,"MEDISERVICE":3150,"PARTICULAR":3500,"PARTICULAR COM NF":3500,"PARTICULAR RM":3500,"PLASC":3200,"PM":1861.42,"SABIN SINAI":5119.44,"SAUDE SERVIDOR":3301.8,"ESTADO":3000,"UNIMED PF":2071,"UNIMED PJ":2071}'),
('IV EYLIA 8mg', '{"AME":3500,"AMIL":3800,"AMIL RM":3800,"BRADESCO":3150,"CAIXA":5115.9,"CASSI":3982.69,"CEMIG":5438.82,"FUSEX":3160.52,"GNDI":3800,"MEDISERVICE":3150,"PARTICULAR":3500,"PARTICULAR COM NF":3500,"PARTICULAR RM":3500,"PLASC":3200,"PM":1861.42,"SABIN SINAI":5119.44,"SAUDE SERVIDOR":2071,"ESTADO":3000,"UNIMED PF":2071,"UNIMED PJ":2071}'),
('IV LUCENTIS', '{"AME":3500,"AMIL":3800,"AMIL RM":3800,"BRADESCO":3150,"CAIXA":4822.08,"CASSI":3982.69,"CEMIG":5438.82,"FUSEX":3160.52,"GNDI":3800,"MEDISERVICE":3150,"PARTICULAR":3500,"PARTICULAR COM NF":3500,"PARTICULAR RM":3500,"PLASC":3200,"PM":1861.42,"SABIN SINAI":5119.44,"SAUDE SERVIDOR":2071,"ESTADO":3000,"UNIMED PF":2071,"UNIMED PJ":2071}'),
('IV OZURDEX', '{"AMIL":3950,"AMIL RM":3950,"CAIXA":3485.16,"GNDI":4700,"PARTICULAR":5500,"PARTICULAR COM NF":5500,"PARTICULAR RM":5500,"PLASC":6500,"PM":3948.73,"SAUDE SERVIDOR":4066.9,"ESTADO":0,"UNIMED PJ":172.38}'),
('IV VABYSMO', '{"AME":3500,"AMIL":3800,"AMIL RM":3800,"BRADESCO":3150,"CAIXA":5115.9,"CASSI":3982.69,"CEMIG":5438.82,"FUSEX":3160.52,"GNDI":3800,"MEDISERVICE":3150,"PARTICULAR":3500,"PARTICULAR COM NF":3500,"PARTICULAR RM":3500,"PLASC":3200,"PM":1861.42,"SABIN SINAI":5119.44,"SAUDE SERVIDOR":2071,"ESTADO":3000,"UNIMED PF":2071,"UNIMED PJ":2071}'),
('Implante de Polimero', '{"CAIXA":865.73,"PARTICULAR":10000,"PARTICULAR COM NF":11000,"PLASC":6500,"PM":1086.76,"SAUDE SERVIDOR":816.81,"ESTADO":0,"UNIMED PF":643.47,"UNIMED PJ":643.47}'),
('Tratamento ocular quimioterápico', '{"AME":11700,"CEMIG":643.15,"PM":778.77,"SABIN SINAI":561.94,"SAUDE SERVIDOR":680.5,"ESTADO":0,"UNIMED PF":459.62,"UNIMED PJ":459.62}'),
('Pacote de tratamento ocular', '{"CEMIG":2600,"ESTADO":0,"UNIMED PJ":3150}')
ON CONFLICT (nome) DO NOTHING;
