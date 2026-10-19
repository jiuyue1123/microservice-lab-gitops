# microservice-lab GitOps

微服务实验平台的 GitOps 仓库。集群是单节点 k3s，入口用 Traefik，部署由 Argo CD 管理。

平台包含 MySQL、Nacos、Redis、RabbitMQ。user-service 和 gateway 已部署，auth-service、order-service、tenant-service 目前仍是目录占位。

## 部署流程

按顺序执行，前一步验证通过再继续。

1. **准备 Argo CD 仓库访问**

   Argo CD 需要能 clone `git@github.com:jiuyue1123/microservice-lab-gitops.git`。集群里需要一个 GitHub 的 `repo-creds`：

   ```bash
   kubectl -n argocd create secret generic repo-creds-github-jiuyue \
     --from-literal=type=git \
     --from-literal=url=git@github.com:jiuyue1123 \
     --from-file=sshPrivateKey=/root/.ssh/id_rsa_jiuyue \
     --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n argocd label secret repo-creds-github-jiuyue \
     argocd.argoproj.io/secret-type=repo-creds --overwrite
   ```

   确认 `argocd-ssh-known-hosts-cm` 里有 `github.com` 的 host key；没有的话用 `ssh-keyscan github.com` 补上。

2. **创建运行 Secret**

   ```bash
   ./bootstrap/secrets.sh
   ```

   脚本会创建平台 Secret，写入 `.secrets.env`；首次运行还会生成 `.env`，并据此在 `microservice-lab-apps` 创建 `app-common-env` 和 `user-service-db`。`.env` 是应用环境变量的唯一入口，修改后重新运行脚本并重启两个 Deployment。

3. **准备 Nacos**

   首次访问控制台设置 admin 密码，然后：

   - 创建 namespace `microservice-lab`
   - 创建用户 `mslab`，密码取 `nacos-client-credentials`
   - 创建角色并授予该 namespace 的读写权限
   - 在 `DEFAULT_GROUP` 创建 `gateway.yaml`：

   ```yaml
   spring:
     cloud:
       gateway:
         server:
           webflux:
             routes:
               - id: user-service
                 uri: lb://user-service
                 predicates:
                   - Path=/users/**
   ```

4. **网关 TLS**

   在 `/root/coredns/coredns-custom.yaml` 增加 `gateway IN A 192.168.0.132`，SOA serial 加一；在 `/root/coredns/certs/make-certs.sh` 的 `HOSTS` 增加 `gateway.lan`，重签证书后执行：

   ```bash
   ./bootstrap/tls-secret.sh
   ```

   脚本会在 `microservice-lab-apps` 创建 `gateway-lan-tls`。

5. **启动 Argo CD**

   ```bash
   kubectl apply -k bootstrap
   ```

   子 Application 按 wave 创建：`-10` 命名空间 → `-5` StorageClass → `10` 五个 MySQL → `15` Nacos schema Job → `18` Nacos → `20` Redis、RabbitMQ → `30` user-service → `35` gateway。

6. **验证**

   ```bash
   kubectl -n argocd get applications
   kubectl -n microservice-lab-platform get pods,jobs
   kubectl -n microservice-lab-apps get pods
   curl -s --cacert /root/coredns/certs/ca.crt -o /dev/null -w '%{http_code}\n' https://gateway.lan/users
   ```

   期望：所有 Application `Synced/Healthy`，平台和两个应用都 Running，`nacos-schema` Job 完成。

## 组件

| Application | 命名空间 | 来源 | 版本 / 镜像 | PVC |
|---|---|---|---|---|
| namespaces | argocd | `infrastructure/namespaces` | — | — |
| storage | argocd | `infrastructure/storage` | `microservice-lab-local` | — |
| mysql-auth | microservice-lab-platform | `groundhog2k/mysql` | `3.1.4` / `mysql:8.4.11` | 5Gi |
| mysql-order | microservice-lab-platform | `groundhog2k/mysql` | `3.1.4` / `mysql:8.4.11` | 5Gi |
| mysql-tenant | microservice-lab-platform | `groundhog2k/mysql` | `3.1.4` / `mysql:8.4.11` | 5Gi |
| mysql-user | microservice-lab-platform | `groundhog2k/mysql` | `3.1.4` / `mysql:8.4.11` | 5Gi |
| mysql-nacos | microservice-lab-platform | `groundhog2k/mysql` | `3.1.4` / `mysql:8.4.11` | 5Gi |
| nacos | microservice-lab-platform | `platform/nacos` | `nacos/nacos-server:v3.2.4` | 2Gi（日志） |
| redis | microservice-lab-platform | `cloudpirates/redis` | `0.37.2` / `redis:8.10.2` | 2Gi |
| rabbitmq | microservice-lab-platform | `cloudpirates/rabbitmq` | `0.21.31` / `rabbitmq:4.3.6-management` | 2Gi |
| user-service | microservice-lab-apps | `apps/user-service` | `harbor.lan/microservice-lab/user-service:v1` | — |
| gateway | microservice-lab-apps | `apps/gateway` | `harbor.lan/microservice-lab/gateway:gateway-v1` | — |

## 数据库

四个业务服务各用一个独立 MySQL 实例，Nacos 单独用一个：

| 实例 | 数据库 | 应用用户 | Secret |
|---|---|---|---|
| mysql-auth | `auth_db` | `auth` | `mysql-auth-credentials` |
| mysql-order | `order_db` | `order` | `mysql-order-credentials` |
| mysql-tenant | `tenant_db` | `tenant` | `mysql-tenant-credentials` |
| mysql-user | `user_db` | `user` | `mysql-user-credentials` |
| mysql-nacos | `nacos` | `nacos` | `mysql-nacos-credentials` |

业务库的建表和迁移由应用内的 Flyway 负责，仓库里没有业务 schema Job。Nacos 库由 `nacos-schema` Job 使用官方 3.2.4 的 `mysql-schema.sql` 初始化。

## Nacos

- 镜像 `nacos/nacos-server:v3.2.4`，standalone 模式，后端使用 `mysql-nacos`。
- 开启鉴权：`NACOS_AUTH_ENABLE`、console/admin 认证都打开。
- 端口：API 8848，gRPC 9848/9849，Raft 7848，控制台 8080。
- 控制台不暴露 Ingress，开发机通过 port-forward 访问。
- 第一次打开控制台要设置 `nacos` 管理员密码；`nacos-secrets` 里的 token/identity 是服务端认证配置，不是控制台密码。
- 使用独立 namespace `microservice-lab`；业务用户 `mslab` 需要在控制台创建并授予该 namespace 的读写权限。
- `microservice-lab` namespace 的 `DEFAULT_GROUP` 下需要创建 `gateway.yaml`，内容见部署流程。网关只配置了 `/users/**` 路由，不带 `/api` 前缀。
- `nacos-client-credentials` 预留给业务服务连接 Nacos。

## Secret

| 命名空间 | Secret | Keys |
|---|---|---|
| microservice-lab-platform | `mysql-auth-credentials` | `mysql-root-password`, `mysql-password`, `mysql-database`, `mysql-username` |
| microservice-lab-platform | `mysql-order-credentials` | 同上 |
| microservice-lab-platform | `mysql-tenant-credentials` | 同上 |
| microservice-lab-platform | `mysql-user-credentials` | 同上 |
| microservice-lab-platform | `mysql-nacos-credentials` | 同上 |
| microservice-lab-platform | `redis-credentials` | `redis-password` |
| microservice-lab-platform | `rabbitmq-credentials` | `rabbitmq-password`, `rabbitmq-erlang-cookie` |
| microservice-lab-platform | `nacos-secrets` | `auth-token`, `auth-identity-key`, `auth-identity-value` |
| microservice-lab-platform | `nacos-client-credentials` | `username`, `password` |
| microservice-lab-platform | `jwt-secret` | `jwt-secret` |
| microservice-lab-apps | `app-common-env` | `.env` 中除 `DB_` 外的 key |
| microservice-lab-apps | `user-service-db` | `.env` 中的 `DB_` key |

`rabbitmq-erlang-cookie` 建好后不要再改。Nacos 的 `auth-token` 是 base64，解码后至少 32 字节。应用环境变量统一由 `.env` 生成，模板见 `.env.example`；`.env` 不入库。

## 凭据获取

自动生成的值都在 `.secrets.env`，也可以直接从集群读取：

```bash
# 五个 MySQL 的应用用户密码，把 auth 换成 order/tenant/user/nacos
kubectl -n microservice-lab-platform get secret mysql-auth-credentials -o jsonpath='{.data.mysql-password}' | base64 -d
# root 密码
kubectl -n microservice-lab-platform get secret mysql-auth-credentials -o jsonpath='{.data.mysql-root-password}' | base64 -d

# Redis
kubectl -n microservice-lab-platform get secret redis-credentials -o jsonpath='{.data.redis-password}' | base64 -d

# RabbitMQ，用户名 admin
kubectl -n microservice-lab-platform get secret rabbitmq-credentials -o jsonpath='{.data.rabbitmq-password}' | base64 -d

# Nacos 服务端认证
kubectl -n microservice-lab-platform get secret nacos-secrets -o jsonpath='{.data.auth-token}' | base64 -d
kubectl -n microservice-lab-platform get secret nacos-secrets -o jsonpath='{.data.auth-identity-key}' | base64 -d
kubectl -n microservice-lab-platform get secret nacos-secrets -o jsonpath='{.data.auth-identity-value}' | base64 -d

# Nacos 业务用户（需要先在 Nacos 里创建）
kubectl -n microservice-lab-platform get secret nacos-client-credentials -o jsonpath='{.data.password}' | base64 -d

# JWT
kubectl -n microservice-lab-platform get secret jwt-secret -o jsonpath='{.data.jwt-secret}' | base64 -d

# 应用环境变量（从 .env 生成）
kubectl -n microservice-lab-apps get secret app-common-env -o jsonpath='{.data.NACOS_PASSWORD}' | base64 -d
kubectl -n microservice-lab-apps get secret user-service-db -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

## 端口转发

`hack/port-forward.sh` 一次启动开发需要的端口：

| 服务 | 本地端口 |
|---|---:|
| Nacos 控制台 | 8081 → 8080 |
| Nacos HTTP API | 8848 |
| Nacos gRPC | 9848 / 9849 |
| Nacos Raft | 7848 |
| MySQL auth | 3307 |
| MySQL order | 3308 |
| MySQL tenant | 3309 |
| MySQL user | 3310 |
| MySQL nacos | 3311 |
| Redis | 6379 |
| RabbitMQ AMQP | 5672 |
| RabbitMQ 管理 | 15672 |
| user-service | 18081 → 8081 |
| gateway | 18080 → 8080 |

```bash
./hack/port-forward.sh start
./hack/port-forward.sh status
./hack/port-forward.sh stop
```

默认绑定 `127.0.0.1`。在 k3s 节点上给局域网开发机使用时：

```bash
BIND_ADDRESS=0.0.0.0 ./hack/port-forward.sh start
```

然后访问 `192.168.0.132:<端口>`。端口被占用时会跳过该服务；可以用环境变量改本地端口，例如 `MYSQL_AUTH_PORT=13307`。日志和 PID 在 `/tmp/microservice-lab-port-forward`。

Gateway 也可以直接走 `https://gateway.lan`，不依赖 port-forward。

## 业务服务

- `apps/user-service`：已部署，镜像 `user-service:v1`，端口 8081，Flyway 负责 `user_db` 的迁移。
- `apps/gateway`：已部署，镜像 `gateway:gateway-v1`，端口 8080，Ingress `gateway.lan`。
- `apps/auth-service`、`order-service`、`tenant-service`：目录占位，后续补。
- 网关路由配置在 Nacos 的 `gateway.yaml`，当前只配置了 `/users/**`；gateway 目前没有 JWT/认证过滤器，鉴权后续再加。

## 存储与容量

- StorageClass：`microservice-lab-local`（`rancher.io/local-path`，`Retain`，`WaitForFirstConsumer`）。
- PVC 合计约 31Gi：五个 MySQL 25Gi、Redis 2Gi、RabbitMQ 2Gi、Nacos 日志 2Gi。
- 当前没有可观测性组件；后续加 Prometheus/Loki/Grafana 时需要重新评估内存和磁盘。
- 五个 MySQL 和 Nacos 的 requests 合计约 1.8C/3.3Gi，limits 约 4.5C/5.8Gi。
- user-service 和 gateway 再加约 0.35C/0.75Gi requests、1.5C/1.5Gi limits。当前节点余量够用，后续加服务时再评估。

## 删除和备份

所有 Application 都没有 `resources-finalizer`，删除 Application 不会级联删除底层资源。StorageClass 的 `reclaimPolicy` 是 `Retain`，PVC 删除后 PV 和数据还在。

仓库没有自动备份。建议：

- 五个 MySQL 定期 `mysqldump` 到 NAS 或对象存储。
- Nacos 的 MySQL 库一起备份。
- RabbitMQ 备份数据卷并导出 definitions。
- 备份不要放在同一个节点或同一块盘上。

## 本地检查

```bash
./hack/validate.sh
```

会构建所有 kustomize 目录、渲染五个 MySQL 和 Redis/RabbitMQ 的 chart，并检查 Application 的 `ServerSideApply` 和 finalizer。不连集群，也不会部署。
