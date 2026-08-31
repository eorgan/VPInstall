# VPInstall

Instalador de VPS: prepara o servidor e sobe as stacks em Docker Swarm atrás do
Traefik com TLS, a partir de um único domínio raiz e sem digitar senhas.

## Uso

Numa máquina que já tenha Docker e Swarm ativos:

```bash
git clone https://github.com/eorgan/VPInstall.git
cd VPInstall
./install.sh --domain exemplo.com.br --email voce@exemplo.com.br
```

O script gera todas as credenciais, guarda em `.env` (modo 600) e implanta as
stacks na ordem de dependência. Rodar de novo é seguro: os segredos existentes
são reaproveitados, então este é também o caminho de atualização.

Para ver o que seria feito, sem tocar no cluster:

```bash
./install.sh --dry-run --domain exemplo.com.br --email voce@exemplo.com.br
```

## Stacks

| Stack | Host | Tier |
|---|---|---|
| Traefik | — | 10 |
| Portainer | `portainer.<domínio>` | 10 |
| PostgreSQL (pgvector) | — | 20 |
| Redis | — | 20 |
| Evolution API | `evo.<domínio>` | 30 |

Aponte os registros DNS para o servidor **antes** de rodar, senão o Let's
Encrypt não consegue emitir os certificados.

## Segurança

- **Atualizações.** Rodar `./install.sh` de novo é seguro: os segredos existentes
  em `.env` são reaproveitados. Regenerá-los quebraria o acesso ao banco ao vivo.

- **Arquivo `.env`.** Contém todas as credenciais geradas, é criado com modo 600
  e nunca deve ser commitado (é ignorado por padrão em `.gitignore`).

- **Portas do banco de dados.** PostgreSQL e Redis não publicam portas
  deliberadamente — são acessíveis apenas pela rede interna do overlay. Observe
  que `ufw` não bloqueia portas publicadas por Docker — Swarm insere as regras
  DNAT antes de `ufw` — então não publicar é a proteção real.

- **DNS e Let's Encrypt.** Os registros DNS devem apontar para o servidor antes
  da primeira execução, senão Let's Encrypt não consegue emitir os certificados
  e fica com rate limit em tentativas falhadas.

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

Os campos `STACK_SUBDOMAIN` e `STACK_SECRETS` podem estar vazios. O
`stack_pre_deploy` é opcional.

## Testes

```bash
./tests/run.sh
```

Rodam sem Docker e sem dependências externas.

## Licença

[MIT](LICENSE)
