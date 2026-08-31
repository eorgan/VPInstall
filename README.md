# VPInstall

Instalador de VPS: prepara os recursos do Docker Swarm e sobe as stacks atrás do
Traefik com TLS, a partir de um único domínio raiz e sem você digitar senhas.
Todas as credenciais são geradas pelo script e guardadas em `.env` (modo 600).

**O que ele não faz:** não instala o Docker, não roda `docker swarm init`, não
configura firewall e não faz backup. Ele assume um nó de Swarm já pronto.

## Pré-requisitos

- Uma VPS Linux com **Docker instalado** e **Swarm ativo** (`docker swarm init`).
- Rodar num nó **manager** — o script recusa nós worker.
- Acesso ao daemon do Docker: ser `root` ou estar no grupo `docker`.
- Portas **80** e **443** livres no host (o Traefik as publica em modo `host`).
- Os utilitários `openssl`, `envsubst`, `sed` e `grep` no PATH.

## 1. Aponte o DNS

Crie estes registros **A** apontando para o IP da VPS, e espere propagar:

| Registro | Aponta para |
|---|---|
| `portainer.<seu-domínio>` | IP da VPS |
| `evo.<seu-domínio>` | IP da VPS |

Faça isso **antes** de instalar. O Let's Encrypt valida por desafio HTTP: se o
nome ainda não resolve, o certificado não é emitido e cada tentativa falha
consome a cota de falhas de validação.

## 2. Instale

```bash
git clone https://github.com/eorgan/VPInstall.git
cd VPInstall
./install.sh --domain exemplo.com.br --email voce@exemplo.com.br
```

O script gera os segredos, cria a rede e os volumes, renderiza os composes em
`dist/` (modo 700) e implanta as stacks na ordem de dependência, esperando cada
uma convergir antes da seguinte.

Se você omitir `--domain` ou `--email`, ele pergunta. Depois da primeira
execução os dois ficam salvos em `.env` e não são mais pedidos.

Para ver o que aconteceria, sem tocar no cluster nem exigir Docker:

```bash
./install.sh --dry-run --domain exemplo.com.br --email voce@exemplo.com.br
```

## 3. Confira e acesse

```bash
docker stack ls                        # as 5 stacks devem aparecer
docker service ls                      # réplicas em 1/1
docker service logs -f traefik_traefik # acompanhar a emissão dos certificados
```

- **Portainer** — `https://portainer.<domínio>`. O primeiro acesso é onde você
  cria o usuário admin; faça isso logo depois do deploy.
- **Evolution API** — `https://evo.<domínio>`. Autentique com o header
  `apikey`, cujo valor é o `EVOLUTION_API_KEY` do seu `.env`.
- **PostgreSQL e Redis** não têm endereço público: são acessíveis só de dentro
  do overlay, pelos nomes `postgres` e `redis`.

## Atualizar

Rode `./install.sh` de novo. É seguro: os segredos já presentes em `.env` são
reaproveitados (regenerá-los quebraria o acesso ao banco ao vivo), as imagens
são reresolvidas e serviços removidos das stacks são podados.

## Stacks

| Stack | O que é | Endereço | Tier |
|---|---|---|---|
| Traefik | Proxy reverso, TLS automático via Let's Encrypt | — | 10 |
| Portainer | Painel web para gerenciar o Swarm | `portainer.<domínio>` | 10 |
| PostgreSQL | Banco relacional, imagem `pgvector` | interno | 20 |
| Redis | Cache em memória | interno | 20 |
| Evolution API | API de WhatsApp | `evo.<domínio>` | 30 |

**Tier** é a ordem de implantação: menor primeiro. As stacks de tier 30 esperam
o PostgreSQL aceitar conexões antes de subir.

## Segurança

- **Arquivo `.env`.** Contém todas as credenciais geradas, é criado com modo 600
  e nunca deve ser commitado (já está no `.gitignore`, junto com `dist/`).

- **Portas do banco de dados.** PostgreSQL e Redis não publicam portas
  deliberadamente. Observe que `ufw` não bloqueia portas publicadas por Docker
  — o Swarm insere as regras DNAT antes do `ufw` — então não publicar é a
  proteção real, não a regra de firewall.

- **Rate limit do Let's Encrypt.** Tentativas falhas contam contra a cota. Se o
  DNS ainda não propagou, use `--dry-run` até estar pronto, em vez de tentar o
  deploy repetidamente.

## Se der errado

| Mensagem | O que fazer |
|---|---|
| `cannot talk to the Docker daemon` | Rode como `root` ou entre no grupo `docker` (`usermod -aG docker $USER`, depois relogue). |
| `Docker Swarm is not active on this node` | `docker swarm init` (o VPInstall não faz isso por você). |
| `this node is a swarm worker, not a manager` | Rode num manager; veja quais são com `docker node ls`. |
| `missing required command(s): ...` | Instale o que faltou — em Debian/Ubuntu, `envsubst` vem no pacote `gettext-base`. |
| Certificado não emite | Confirme que o nome resolve para o IP da VPS e que as portas 80/443 chegam nele; veja `docker service logs traefik_traefik`. |
| Portainer diz que a instância expirou | A janela de criação do admin fechou. Reinicie o serviço: `docker service update --force portainer_portainer`. |

## Adicionar uma stack

Crie dois arquivos e nada mais — `install.sh` não muda:

- `stacks/<categoria>/<nome>.yml` — o compose, com `${DOMAIN}` e `${SEGREDO}`
- `stacks/<categoria>/<nome>.stack` — o manifesto (nome, tier, subdomínio,
  segredos, volumes e um `stack_pre_deploy` opcional)

O manifesto segue este padrão:

```
STACK_NAME="nome"
STACK_FILE="stacks/categoria/nome.yml"
STACK_TIER=30
STACK_SUBDOMAIN="subdominio"
STACK_SECRETS="SEGREDO1 SEGREDO2"
STACK_VOLUMES="volume1 volume2"
```

Os segredos listados em `STACK_SECRETS` passam a ser gerados automaticamente e
só eles ficam disponíveis para substituição no compose. Os campos
`STACK_SUBDOMAIN` e `STACK_SECRETS` podem estar vazios, e `stack_pre_deploy` —
usado, por exemplo, para criar um papel e um banco no PostgreSQL antes do
deploy — é opcional.

## Testes

```bash
./tests/run.sh
```

Rodam sem Docker e sem dependências externas.

## Licença

[MIT](LICENSE)
