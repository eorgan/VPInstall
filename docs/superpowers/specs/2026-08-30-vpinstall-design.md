# VPInstall — Design

**Data:** 2026-08-30
**Status:** aguardando revisão
**Repositório:** https://github.com/eorgan/VPInstall

---

## 1. Objetivo

Um repositório único que leva uma VPS Ubuntu limpa até um Docker Swarm com as
stacks rodando atrás do Traefik com TLS, informando **um único domínio raiz** e
sem digitar nenhuma senha — todas as credenciais são geradas pelo instalador.

Substitui o fluxo manual do `eorgan/quickstack`, onde domínio e segredos eram
editados à mão dentro dos YAMLs e acabaram commitados num repositório público.

## 2. Arquitetura: duas portas de entrada

O ponto central do design. Não é um script só.

```
setup-server.sh   uma vez, root, prepara o Ubuntu
install.sh        idempotente, sobe e atualiza as stacks
vpinstall         wrapper: numa máquina nova, roda os dois em sequência
```

**Por que separados.** Os dois têm ciclos de vida opostos. O `install.sh` é o
caminho de *atualização* — é o que você roda para subir a versão de uma imagem,
e portanto roda muitas vezes. O `setup-server.sh` reconfigura SSH, firewall e
auditoria: roda uma vez, no provisionamento, e tem raio de alcance de máquina
inteira. Fundir os dois faria toda troca de tag de imagem arrastar junto uma
reconfiguração de SSH — o tipo de acoplamento que faz alguém ter medo de rodar
o próprio instalador.

O wrapper existe para que máquina nova continue sendo um comando só.

## 3. Estrutura de arquivos

```
setup-server.sh
install.sh
vpinstall
lib/
  common.sh        log, die, preflight, confirmação
  secrets.sh       geração e merge idempotente do .env
  render.sh        envsubst + validação
  postgres.sh      gate de readiness + criação de role/db
stacks/
  infra/traefik.yml       traefik.stack
  infra/portainer.yml     portainer.stack
  db/postgres.yml         postgres.stack
  db/redis.yml            redis.stack
  app/evolution-api.yml   evolution-api.stack
docs/superpowers/specs/
.env.example
.gitignore        .env  dist/
LICENSE
```

Gerados, nunca versionados: `.env` (chmod 600) e `dist/` (chmod 700).

## 4. install.sh

### 4.1 Manifesto por stack

Um fragmento shell por stack, ao lado do YAML. Adicionar uma stack nova é criar
dois arquivos — **zero alteração no `install.sh`**.

```sh
# stacks/app/evolution-api.stack
STACK_NAME="evolution"
STACK_FILE="stacks/app/evolution-api.yml"
STACK_TIER=30                          # 10 infra · 20 db · 30 app
STACK_SUBDOMAIN="evo"                  # vazio = não publica host
STACK_SECRETS="EVOLUTION_API_KEY EVOLUTION_DB_PASSWORD"
STACK_VOLUMES="evolution_instances evolution_store"

stack_pre_deploy() {                   # opcional
  pg_ensure_role_db evolution "$EVOLUTION_DB_PASSWORD"
}
```

Descoberta por `stacks/*/*.stack`, ordenação por `STACK_TIER`.

O hook `stack_pre_deploy` resolve um bug real herdado do quickstack: o
`postgres.yml` só cria o superusuário `postgres`, mas o Evolution conecta como
`evolution` no banco `evolution` — que ninguém criava. Só funcionava se alguém
tivesse rodado o SQL à mão.

### 4.2 Domínio

Uma pergunta só: o domínio raiz. Cada manifesto traz seu prefixo e o script
monta os hostnames.

```
DOMAIN=exemplo.com.br
  -> portainer.exemplo.com.br
  -> evo.exemplo.com.br
```

`DOMAIN` e `ACME_EMAIL` são perguntados na primeira execução, guardados no
`.env` e reusados depois. Flags `--domain` e `--email` sobrescrevem.

### 4.3 Segredos

`openssl rand -hex 32`.

**Hex e não base64, de propósito:** a senha do Postgres entra dentro de uma URI
(`postgresql://evolution:SENHA@postgres:5432/...`) e base64 emite `/` e `+`,
que corrompem a DSN silenciosamente. Hex é URL-safe por construção.

Merge idempotente: se o `.env` existe, é carregado e **preservado**; só são
geradas as variáveis declaradas em algum `STACK_SECRETS` que ainda não existam.
Rodar duas vezes nunca quebra o acesso ao banco.

Valores derivados não vão para o `.env` — são montados na renderização
(`EVOLUTION_HOST`, a `DATABASE_CONNECTION_URI` completa).

### 4.4 Renderização

`envsubst` com **allowlist explícita** de variáveis. Sem a allowlist ele devora
qualquer `${...}` do arquivo — hoje inofensivo, mas quebraria ao trazer n8n e
Chatwoot, cujas configs usam `$` legítimo.

Duas travas antes de tocar no cluster:

1. `grep '\${' dist/*.yml` — se sobrou variável não resolvida, aborta e aponta onde.
2. `docker stack config -c` em cada arquivo.

Essa validação é a razão de renderizar para `dist/` em vez de deixar o
`docker stack deploy` interpolar direto: com interpolação nativa, variável
ausente vira string vazia e você descobre com o Traefik roteando `Host()` vazio
ou o Postgres subindo sem senha.

### 4.5 Sequência

```
preflight   docker · swarm ativo · nó manager · openssl · envsubst
recursos    rede network_public (overlay/attachable) + volumes externos
segredos    .env  (gera só o que falta)
render      stacks/ -> dist/  + validação
dns         checagem NÃO-fatal: cada host resolve para o IP público?
tier 10     traefik, portainer
tier 20     postgres, redis
gate        pg_isready em loop, com timeout e erro claro
hooks       stack_pre_deploy -> cria role/db 'evolution'
tier 30     evolution-api
resumo      URLs, caminho do .env, registros DNS necessários
```

A checagem de DNS é aviso, não erro. Vale muito mesmo assim: DNS não apontado é
a causa mais comum de "o Traefik não emitiu o certificado", e o Let's Encrypt
tem rate limit — avisar antes evita queimar tentativas.

## 5. setup-server.sh

**Escrito a partir de requisitos, não copiado.** O `felipefontoura/ubinkaze`
resolve o mesmo problema, mas **não tem arquivo de licença** — sem licença, o
padrão é todos os direitos reservados, então copiar o código não é uma opção.
Reproduzir a funcionalidade é legítimo; copiar o arquivo não.

Requisitos:

- Verificar Ubuntu 24.04, RAM e disco mínimos; abortar cedo com mensagem clara
- `apt update && upgrade`, pacotes essenciais
- Docker CE via repositório oficial + `docker swarm init`
- SSH: desabilitar login de root por senha e autenticação por senha,
  **apenas depois de confirmar que existe chave pública instalada** — caso
  contrário o script tranca o operador para fora
- UFW: negar entrada por padrão, permitir 22/80/443
- `unattended-upgrades` para patches de segurança
- Fuso horário e sincronização de relógio (TLS depende de relógio correto)

Idempotente: rodar de novo não deve duplicar regra de firewall nem reescrever
config de SSH já correta.

## 6. Segurança

- `.env` em 600, `dist/` em 700
- Nenhum segredo em stdout — o resumo imprime caminhos, nunca valores
- Nenhuma porta de banco publicada. Postgres e Redis conversam pela overlay
  interna. Observação para o futuro: **`ufw` não bloqueia porta publicada pelo
  Docker** — o Swarm insere DNAT em `nat/PREROUTING`, antes do ufw. A única
  contenção real é não publicar
- Redis sem `requirepass` é aceitável **somente** enquanto não houver porta
  publicada. Se algum dia publicar, a senha passa a ser obrigatória
- `.gitignore` cobrindo `.env` e `dist/` desde o primeiro commit

## 7. Licença e proveniência

Os YAMLs das stacks derivam de `felipefontoura/bento` (MIT). A MIT exige que o
aviso de copyright acompanhe o código, então o `LICENSE` do VPInstall preserva
o copyright do Felipe e adiciona o nosso. Isso precisa existir **antes** do
primeiro código entrar, já que o repositório é público.

Nada do `ubinkaze` é copiado (ver seção 5).

## 8. Testes

Sem um Swarm real, o que dá para testar de verdade:

- **`--dry-run`** — executa tudo menos `stack deploy` e hooks; cobre todo o
  caminho de configuração e renderização localmente
- `shellcheck` em todos os `.sh`
- Parse YAML de cada arquivo renderizado
- **Idempotência** — roda `--dry-run` duas vezes e verifica que o `.env` não
  mudou (`diff`)

## 9. Fora de escopo

Backup, monitoramento, multi-nó, rotação automática de segredos, e as 5 stacks
hoje deletadas no quickstack (chatwoot, n8n, typebot, plunk, rabbitmq). O
formato de manifesto é o ponto de extensão para elas depois.

## 10. Pendências

- Migrar os 5 YAMLs do quickstack, já com as correções da branch
  `fix/v3-compat-and-image-updates` (Traefik v3, imagens atualizadas, portas
  fechadas), trocando domínio e segredos por `${...}`
- Corrigir a descrição do repositório no GitHub: "snacks" -> "stacks"
