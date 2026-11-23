# Especificação do código: Funções puras e testabilidade em Elixir

Este arquivo descreve o código a ser gerado para o experimento do artigo. Ele pode ser entregue diretamente a um assistente de código (Claude Code, por exemplo) como instrução de implementação.

## 0. Padrão de código: inglês

Todo o código deve ser escrito em **inglês**, sem exceção:

- nomes de apps, módulos, funções, variáveis, atoms, structs, campos e arquivos;
- `@moduledoc`, `@doc`, comentários e mensagens de log;
- descrições de `describe`/`test`/`property` nos testes;
- mensagens de erro, nomes de colunas do CSV de métricas e README.

Seguir as convenções da comunidade Elixir: `snake_case` para funções, variáveis e arquivos; `PascalCase` para módulos; formatação com `mix format`. Apenas este documento de especificação está em português.

## 1. Objetivo do código

Implementar **duas variantes funcionalmente equivalentes** do mesmo sistema de processamento de pedidos:

- **Variante A – `orders_pure`**: lógica de negócio em funções puras (*functional core*), com efeitos colaterais isolados em uma camada fina (*imperative shell*).
- **Variante B – `orders_mixed`**: a mesma lógica, mas com efeitos colaterais (tempo, estoque, pagamento, notificação) chamados diretamente dentro das funções de negócio.

As duas variantes devem expor **a mesma API pública** e passar **o mesmo conjunto de testes de aceitação**. A diferença entre elas deve estar apenas na organização do código, nunca nas regras de negócio.

## 2. Ambiente

- Elixir 1.17+ e Erlang/OTP 27+
- Estrutura: projeto *umbrella* com três apps

```
fp_experiment/
├── apps/
│   ├── shared_domain/      # structs, types and shared behaviours
│   ├── orders_pure/        # Variant A
│   └── orders_mixed/       # Variant B
├── defects/                # seeded defects (section 7)
├── scripts/
│   ├── collect_metrics.exs
│   └── mutate.exs
├── results/
└── mix.exs
```

### Dependências (verificar versões atuais no Hex antes de usar)

| Pacote | Uso | Escopo |
| --- | --- | --- |
| `decimal` ~> 2.1 | Valores monetários | runtime |
| `stream_data` ~> 1.1 | Property-based testing | `:test` |
| `mox` ~> 1.1 | Mocks baseados em behaviours | `:test` |
| `excoveralls` ~> 0.18 | Cobertura de testes | `:test` |
| `credo` ~> 1.7 | Análise estática | `:dev, :test` |
| `dialyxir` ~> 1.4 | Verificação de tipos (Dialyzer) | `:dev` |
| `benchee` ~> 1.3 | Desempenho (opcional) | `:dev` |

Para teste de mutação, avaliar uma das ferramentas do ecossistema (por exemplo `exavier` ou `darwin`). Confirmar se a ferramenta escolhida ainda é mantida e compatível com a versão do Elixir. Caso nenhuma funcione, implementar o script da seção 6.3.

## 3. Domínio: processamento de pedidos

### 3.1 Estruturas (app `shared_domain`)

```elixir
%SharedDomain.Item{
  sku: String.t(),
  quantity: pos_integer(),
  unit_price: Decimal.t()
}

%SharedDomain.Order{
  id: String.t(),
  customer_id: String.t(),
  items: [Item.t()],
  coupon: String.t() | nil,
  zip_code: String.t(),
  status: :new | :reserved | :paid | :cancelled,
  total: Decimal.t() | nil,
  created_at: DateTime.t() | nil
}
```

Usar `Decimal` para valores monetários. Todas as structs devem ter `@type` e todas as funções públicas, `@spec`.

### 3.2 Regras de negócio

1. **Subtotal**: soma de `quantity × unit_price` de todos os itens.
2. **Desconto por quantidade (bulk discount)**: 5% sobre o subtotal se houver 10 ou mais unidades no total.
3. **Cupom**:
   - `"SAVE10"` → 10% de desconto sobre o subtotal.
   - `"FREESHIP"` → zera o frete.
   - Cupom inválido → `{:error, :invalid_coupon}`.
   - Descontos percentuais não se acumulam: aplica-se o maior.
4. **Frete por região (primeiro dígito do `zip_code`)**:
   - `0` a `3` → 15.00
   - `4` a `6` → 25.00
   - `7` a `9` → 35.00
   - Subtotal com desconto acima de 300.00 → frete grátis.
   - `zip_code` inválido → `{:error, :invalid_zip_code}`.
5. **Horário promocional (happy hour)**: pedidos criados entre 00:00 e 05:59 (UTC) recebem 5.00 de desconto extra, sem deixar o total negativo.
6. **Estoque**: cada item deve ter quantidade disponível; caso contrário, `{:error, {:out_of_stock, sku}}`.
7. **Pagamento**: o gateway responde `:approved`, `:declined` ou `{:error, reason}`. Recusa ou erro libera a reserva de estoque e retorna `{:error, :payment_declined}` ou `{:error, {:payment_failed, reason}}`.
8. **Notificação**: após pagamento aprovado, notificar o cliente. Falha na notificação **não** cancela o pedido, apenas é registrada em log.

### 3.3 API pública (idêntica nas duas variantes)

```elixir
@spec process(Order.t()) :: {:ok, Order.t()} | {:error, term()}
@spec calculate_total(Order.t()) :: {:ok, Decimal.t()} | {:error, term()}
@spec cancel(Order.t()) :: {:ok, Order.t()} | {:error, term()}
```

Módulos de entrada: `OrdersPure` e `OrdersMixed`.

### 3.4 Efeitos colaterais (behaviours em `shared_domain`)

| Behaviour | Callbacks | Implementação real |
| --- | --- | --- |
| `SharedDomain.Clock` | `now/0` | `DateTime.utc_now/0` |
| `SharedDomain.Inventory` | `available/1`, `reserve/2`, `release/2` | `Agent` ou ETS em memória |
| `SharedDomain.PaymentGateway` | `charge/2` | Simulador com latência e falhas aleatórias (semente fixa) |
| `SharedDomain.Notifier` | `notify/2` | `Logger` |

## 4. Variante A – `orders_pure`

Organização obrigatória:

```
lib/orders_pure/
├── core/              # pure functions ONLY
│   ├── pricing.ex         # subtotal, discounts, coupon, shipping, happy hour
│   ├── validation.ex      # items, zip code, coupon
│   └── decisions.ex       # given current state, decide next step
└── shell/
    └── processor.ex       # reads effects, calls core, runs effects
```

Regras:

- Módulos em `core/` **não podem** chamar `DateTime.utc_now`, `Agent`, `:ets`, `Logger`, `Process`, `send`, nem nenhum behaviour de efeito. Tudo que precisam (horário, estoque disponível, resposta do pagamento) chega como argumento.
- `Decisions` deve retornar **descrições de efeitos**, por exemplo `[{:reserve, sku, quantity}, {:charge, amount}]`, que o shell executa.
- O shell recebe os módulos de efeito por configuração (`Application.get_env/2`) para permitir substituí-los.
- O core deve concentrar a maior parte das linhas de regra de negócio.

## 5. Variante B – `orders_mixed`

```
lib/orders_mixed/
├── pricing.ex
├── validation.ex
└── processor.ex
```

Regras:

- As funções de negócio chamam os efeitos diretamente onde forem necessários (por exemplo, `Pricing.calculate/1` consulta o `Clock` internamente; `Validation` consulta o `Inventory`).
- Os efeitos continuam acessados via behaviours configuráveis, para permitir testes com Mox. O objetivo é representar um código idiomático e realista, não um código propositalmente ruim.
- Mesma divisão aproximada de responsabilidades e nomes de módulos equivalentes aos da Variante A, para facilitar a comparação.

## 6. Testes

### 6.1 Testes de aceitação (compartilhados)

- Um único conjunto de testes, parametrizado pela variante (por exemplo, `SharedDomain.AcceptanceCase`), que verifica a API pública contra as regras da seção 3.2.
- Mínimo de 25 casos cobrindo: cada desconto, cada faixa de frete, cupom inválido, frete grátis por valor, horário promocional nas bordas (05:59 e 06:00), falta de estoque, pagamento recusado, erro no gateway, falha de notificação e cancelamento.
- Ambas as variantes devem passar em 100% desses testes.

### 6.2 Testes próprios de cada variante

Para cada variante, escrever a suíte que um desenvolvedor escreveria naturalmente para aquela organização:

- **Variante A**: testes unitários do core **sem nenhum mock**, mais poucos testes de integração do shell usando Mox.
- **Variante B**: testes unitários usando Mox sempre que a função tocar um efeito.
- **Ambas**: propriedades com StreamData, no mínimo:
  - `total is never negative`;
  - `total never exceeds subtotal plus max shipping`;
  - `SAVE10 never increases the total`;
  - `item order does not change the total`;
  - `declined payment always releases all reserved stock`.

Marcar os testes com `@tag :unit`, `@tag :integration` e `@tag :property` para permitir contagens separadas.

### 6.3 Teste de mutação

Se nenhuma ferramenta funcionar, implementar `scripts/mutate.exs` com operadores simples aplicados somente aos módulos de regra de negócio:

- trocar `>` por `>=` e `<` por `<=`;
- trocar `+` por `-`;
- substituir constantes numéricas (por exemplo `0.05` por `0.0`);
- remover uma cláusula de `case`/`cond` por vez.

Para cada mutante: aplicar, rodar a suíte da variante, registrar `killed` ou `survived`, reverter.

## 7. Defeitos semeados

Criar em `defects/` **10 defeitos** realistas, cada um como um patch aplicável às duas variantes no ponto equivalente (ex.: `defects/01_bulk_discount_threshold/pure.patch` e `mixed.patch`):

1. `01_bulk_discount_threshold` – desconto por quantidade ativado com 9 unidades.
2. `02_coupon_stacking` – `SAVE10` acumulando com o desconto por quantidade.
3. `03_shipping_region_boundary` – `zip_code` iniciado em `3` caindo na faixa de 25.00.
4. `04_free_shipping_base` – frete grátis calculado sobre o subtotal antes do desconto.
5. `05_happy_hour_boundary` – horário promocional incluindo 06:00.
6. `06_negative_total` – desconto de horário deixando o total negativo.
7. `07_stock_not_released_on_error` – estoque não liberado quando o gateway retorna `{:error, _}`.
8. `08_notification_cancels_order` – falha de notificação cancelando o pedido.
9. `09_reserve_before_coupon_check` – reserva feita antes da validação do cupom, sem liberação no erro.
10. `10_early_rounding` – arredondamento do `Decimal` feito antes da soma do frete.

Os testes de aceitação da seção 6.1 **não** devem ser usados para avaliar esses defeitos. O objetivo é medir quantos são detectados pela suíte própria de cada variante (seção 6.2).

## 8. Coleta de métricas

`scripts/collect_metrics.exs` deve rodar para cada variante e gerar `results/metrics.csv` com as colunas:

| Coluna | Fonte |
| --- | --- |
| `variant` | `pure` ou `mixed` |
| `business_loc` | linhas de código dos módulos de regra |
| `test_loc` | linhas de código dos testes da seção 6.2 |
| `unit_tests`, `integration_tests`, `property_tests` | contagem por tag |
| `mock_count` | número de `expect`/`stub` do Mox nos testes |
| `line_coverage` | ExCoveralls (`mix coveralls.json`) |
| `mutation_score` | mutantes mortos ÷ total |
| `defects_detected` | de 0 a 10, aplicando cada patch da seção 7 |
| `suite_time_ms` | tempo médio de 10 execuções da suíte |
| `credo_issues` | `mix credo --format json` |
| `dialyzer_warnings` | `mix dialyzer --format short` |

## 9. Critérios de aceite do código

- [ ] Todo o código, comentários, docs e nomes de testes estão em inglês.
- [ ] `mix format --check-formatted` passa.
- [ ] `mix test` passa nas duas variantes.
- [ ] Os testes de aceitação compartilhados passam 100% nas duas.
- [ ] Nenhum módulo em `orders_pure/core/` referencia efeitos (verificar com um teste que lê o código-fonte e procura chamadas proibidas).
- [ ] `mix credo --strict` sem alertas de prioridade alta.
- [ ] `mix dialyzer` sem erros.
- [ ] Todos os 10 patches de defeito aplicam e revertem sem conflito.
- [ ] `scripts/collect_metrics.exs` gera o CSV completo.
- [ ] README (em inglês) explica como rodar cada etapa.

## 10. Observações para o artigo

- Registrar a versão exata do Elixir, OTP e de cada dependência no README.
- Fixar a semente do StreamData e do simulador de pagamento para reprodutibilidade.
- Se possível, pedir a uma segunda pessoa que revise se as duas variantes são idiomáticas, para reduzir o risco de a Variante B parecer artificialmente pior.
