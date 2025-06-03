#!/bin/bash

#https://yandex.cloud/ru/docs/tutorials/infrastructure-management/terraform-quickstart#cli_1

function export_iam_token(){
    echo "➡️ обновляем IAM-токен..."
    if YC_TOKEN=$(yc iam create-token); then
        export YC_TOKEN
        export TF_VAR_iam_token="${YC_TOKEN}"
    else
        echo "  ❌ Ошибка при создании IAM токена."
        exit 1
    fi
    export YC_CLOUD_ID=$(yc config get cloud-id)
    export TF_VAR_cloud_id="${YC_CLOUD_ID}"

    export YC_FOLDER_ID=$(yc config get folder-id)
    export TF_VAR_folder_id="${YC_FOLDER_ID}"

    export TF_VAR_sa_id=$(yc iam service-account get editor-sa --format json | jq -r '.id')

    echo "  ✅ IAM-токен обновлён."
}

function sync_terrafrom_backend() {
    # эта функция должна запускаться от профлиля default! 
    # проверяем наличие баета tfsate и если его нету создаём
    local bucket_service_account_id="$1"
    local bucket_folder_id="$2"

    echo "➡️ Проверяем наличие бакета tfsate-${bucket_folder_id}..."
    if [ -z "$(yc storage bucket list | grep "tfsate-${bucket_folder_id}")" ]; then
        echo "➡️ Создаём бакет tfsate для хранения состояния Terraform..."
        if yc storage bucket create --name tfsate-${bucket_folder_id} --folder-id ${TF_VAR_folder_id} --grants grant-type=grant-type-account,grantee-id=${bucket_service_account_id},permission=permission-full-control; then
            echo "  ✅ Бакет tfsate-${bucket_folder_id} создан. Сервисный аккаунт ${bucket_service_account_id} получил доступ permission-full-control на бакет tfsate."
        else
            echo "  ❌ Ошибка при создании бакета tfsate-${bucket_folder_id}."
            return
        fi
    else
        echo "  ✅ [Skipped...]  Бакет tfsate-${bucket_folder_id} уже существует."
        echo "➡️ Проверяем права доступа сервисного аккаунта на бакет tfsate-${bucket_folder_id}..."
        if [ -z "$(yc storage bucket get tfsate-${bucket_folder_id} --format json --jq ".acl.grants[] | select(.grantee_id == \"$bucket_service_account_id\" and .permission == \"PERMISSION_FULL_CONTROL\") | .grantee_id" --with-acl)" ]; then
            echo "  ❌ Сервисный аккаунт ${bucket_service_account_id} не имеет прав FULL_CONTROL на бакет tfsate. Добавляем права..."
            if yc storage bucket update --name tfstate --grants grant-type=grant-type-account,grantee-id=${bucket_service_account_id},permission=permission-full-control; then
                echo "  ✅ Права FULL_CONTROL добавлены сервисному аккаунту ${bucket_service_account_id} на бакет tfsate-${bucket_folder_id}."
            else
                echo "  ❌ Ошибка при добавлении прав доступа сервисному аккаунту на бакет tfsate-${bucket_folder_id}."
                return
            fi
        else
            echo "  ✅ Сервисный аккаунт ${bucket_service_account_id} уже имеет права FULL_CONTROL на бакет tfsate-${bucket_folder_id}."
        fi
    fi

    # поулчить статический ключ доступа для bucket_service_account_id
    # нам нужно иметь secret_key его можно получить только при создании поэтому нужно всегда создавать новый
    # нужно получить id всех ключей доступа, потом для каждого ключа получить его описание и если оно содержит метку удалить его
    echo "➡️ Обновляем статические ключи доступа для сервисного аккаунта ${bucket_service_account_id}..."
    for key_id in $(yc --format json --jq ".[] | .id" iam access-key list --service-account-id ${bucket_service_account_id}); do
        if [ "$(yc --format json --jq '.description' iam access-key get --id ${key_id})" = "meta.ephimeral" ]; then
            echo "  🗑️🔑 Ключ id: $key_id будет удалён так как он имеет метку meta.ephimeral"
            if yc iam access-key delete --id ${key_id}; then
                echo "   ✅ Ключ id: $key_id удалён."
            else
                echo "   ❌ Ошибка при удалении ключа id: $key_id."
            fi
        fi 
    done
    # заного создаём ключи доступа 
    echo "➡️ Создаём ключ доступа для сервисного аккаунта ${bucket_service_account_id}..."
    output=$(yc --format json iam access-key create --service-account-id "${bucket_service_account_id}" --description meta.ephimeral 2>/dev/null)
    local yc_status=$?
    if [ $yc_status -ne 0 ]; then
        echo "  ❌ Ошибка при создании статического ключа доступа для сервисного аккаунта ${bucket_service_account_id}."
        return 1
    fi
    export TF_VAR_access_key=$(echo "$output" | jq -r '.access_key.key_id // empty')
    export TF_VAR_secret_key=$(echo "$output" | jq -r '.secret // empty')
    echo "  ✅ Статический ключ доступа создан."
}

function fetch_domain_name(){
    echo "🌐 Обновляем сведения о доменной зоне."
    output=$(yc --format json --jq '.[].zone' dns zones list | sed 's/.$//')
    local yc_status=$?
    if [ $yc_status -ne 0 ]; then
        echo "  ❌ Ошибка при чтении доменных зон."
        return 1
    fi

    if [ -z "${output}" ]; then
        if [ -z "${TF_VAR_domain_name}" ]; then
            echo "  ⚠️ Доменная зона не найдена, введите домен для регестрации. (example.com)"
            read -p "Please enter domain name: " test_domain_zone
            export TF_VAR_domain_name=$test_domain_zone
            echo "TF_VAR_domain_name=${output}" > .env
        fi
        echo " ➡️ [Pending...] Создание доменной зоны ${TF_VAR_domain_name}"
    else 
        echo "  ✅ [Skipped...] Доменная зона ${output} зарегестрирована."
        export TF_VAR_domain_name=${output}
        echo "TF_VAR_domain_name=${output}" > .env
    fi
}

if [ -n "$(yc config profile list | grep 'sa-terraform' | grep 'ACTIVE')" ]; then
    # текущий активный профиль это sa-terrafrom, прервываем скрипт
    echo "⚠️ Текущий активный профиль sa-terraform."
    export_iam_token
    sync_terrafrom_backend $(yc iam service-account get editor-sa --format json | jq -r '.id') $(yc iam service-account get editor-sa --format json | jq -r '.folder_id')
    fetch_domain_name
    # затем использовать команды с инициализацией бекенда в terraform init
    return
fi

yc init 

echo "➡️ Проверка сервисного аккаунта."

if [ -z "$(yc --format json --jq '.[] | select(.name == "editor-sa" ) | .id' iam service-account list)" ]; then
    echo "🧪 Создаём сервисный аккаунт с правами editor на каталог."
    yc iam service-account create --name editor-sa
    echo "  ✅ Сервисный аккаунт создан."
    export TF_VAR_sa_id=$(yc iam service-account get editor-sa --format json | jq -r '.id')
else
    echo "  ✅ [Skipped...]  Сервисный аккаунт уже присутствует в каталоге."
    export TF_VAR_sa_id=$(yc iam service-account get editor-sa --format json | jq -r '.id')
fi

#!/bin/bash

service_account_id=$(yc iam service-account get editor-sa --format json | jq -r '.id')
folder_id=$(yc iam service-account get editor-sa --format json | jq -r '.folder_id')
cloud_id=$(yc config get cloud-id)

if  [ -z "$service_account_id" ] || [ -z "$folder_id" ]; then
    echo "❌ Ошибка: не удалось получить id сервисного аккаунта или id каталога."
    exit 1
fi

#TODO: получить list_access_bindings SA и проверить есть ли у него роли, если есть editor то пропускаем эту строчку
#После добавления access_binding получить ключ SA и экспортировать в terrafrom
if [ -z "$(yc --format json --jq ".[] | select(.subject.id == \"$service_account_id\" and .role_id == \"editor\") | .role_id" resource-manager folder list-access-bindings --id "$folder_id")" ]; then
  echo "⚒️ Добавляем сервисному аккаунту роли editor, storage.editor, storage.admin на каталог ${folder_id}..."

  yc resource-manager folder add-access-binding "$folder_id" --role editor --subject serviceAccount:"$service_account_id"
  yc resource-manager folder add-access-binding "$folder_id" --role storage.editor --subject serviceAccount:"$service_account_id"
  yc resource-manager folder add-access-binding "$folder_id" --role storage.admin --subject serviceAccount:"$service_account_id"
  yc resource-manager folder add-access-binding "$folder_id" --role storage.uploader --subject serviceAccount:"$service_account_id"

  echo "    ✅ Роли добавлена."
else
  echo "    ✅ [Skipped...]  Сервисный аккаунт уже имеет права editor на каталог."
fi

echo "✅ С сервисным аккаунтом всё нормально."
echo "➡️ Проверяем авторизованные ключи доступа..."

if [ -z "$(yc --format json --jq ".[] | select(.service_account_id == \"$service_account_id\") | .id" iam key list --service-account-id $service_account_id)" ]; then
    echo "  🔑 Ключей нет, создаём авторизованный ключ для сервисного аккаунта id:\"${service_account_id}\"..."
    if yc iam key create --service-account-id "$service_account_id" --folder-id "$folder_id" --output key.json; then
        echo "  ✅ Авторизованный ключ создан."
    else
        echo "  ❌ Произошла ошибка при создании ключа доступа"
        exit 1
    fi
else
    if [ -f "/workspaces/SEO/key.json" ]; then
        echo "  ✅ [Skipped...]  Авторизованный ключ уже был создан."
    else
        echo "  ⚠️ Перезоздаём авторизрованный ключ доступа..."
        if yc iam key create --service-account-id "$service_account_id" --folder-id "$folder_id" --output key.json; then
            echo "  ✅ Авторизованный ключ пересоздан."
        else
            echo " ❌ Произошла ошибка при пересоздании ключа доступа."
            exit 1
        fi
    fi

fi

echo "🔭 Проверяем текущий профиль yc..."
if [ -z "$(yc --format json config profile list | grep "sa-terraform" | grep "ACTIVE")"  ]; then
    if [ -z "$(yc --format json config profile list | grep "sa-terraform")"  ]; then
        # Профиля с сервисным аккаунтом нет создаем профиль и переключаемся
        echo "➡️ Профиль sa-terraform не найден... Создаём новый профиль sa-terrafrom..."
        if yc config profile create "sa-terraform"; then
            echo "  ✅ Профиль sa-terraform создан."
        else
            echo "  ❌ Ошибка при создании профиля."
            exit 1
        fi

        if yc config set service-account-key key.json; then
            echo "  ✅ Ключ добавлен в текущий профиль sa-terraform."
        else
            echo "  ❌ Ошибка при добавлении ключа \"key.json\"."
            exit 1
        fi

        if yc config set cloud-id ${cloud_id}; then
            echo "  ✅ Облако ${cloud_id} добавлено в текущий профиль sa-terraform."
        else
            exit 1
        fi

        if yc config set folder-id ${folder_id}; then
            echo "  ✅ Каталог ${folder_id} добавлен в текущий профиль sa-terraform."
        else
            exit 1
        fi
    else
        # Профиль с сервисным аккаунтом есть но он не активен    
        yc config profile activate sa-terraform
        echo "  ✅ Профиль sa-terraform был активирован для текущего профиля yc."
    fi
else
    # Профиль с сервисным аккаунтом уже есть и он активен
    echo "  ✅ [Skipped...]  Профиль с сервисным аккаунтом sa-terraform уже есть и активен."
fi

export_iam_token
sync_terrafrom_backend $(yc iam service-account get editor-sa --format json | jq -r '.id') $(yc iam service-account get editor-sa --format json | jq -r '.folder_id')
fetch_domain_name





