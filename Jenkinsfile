/* groovylint-disable CompileStatic, GStringExpressionWithinString, LineLength, NestedBlockDepth, DuplicateListLiteral, DuplicateStringLiteral, DuplicateNumberLiteral, NoDef, VariableTypeRequired, UnnecessaryGetter, Instanceof */
pipeline {
  agent { label 'dev' }

  parameters {
    choice(name: 'ENV', choices: ['stage', 'prod'], description: 'Target environment')
    choice(name: 'CreateCAB', choices: ['No', 'Yes'], description: 'Create a new ServiceNow change request')
    choice(
      name: 'ChangeType',
      choices: ['normal', 'expedited', 'emergency'],
      description: 'ServiceNow change type when creating a new ticket'
    )
    string(name: 'Change', defaultValue: '', description: 'Existing ServiceNow change ticket ID (example: CHG000123)')
    string(
      name: 'SNOW_SERVICE_NAME',
      defaultValue: 'APIM-Party-Reference-Test',
      description: 'Service name passed to createSNOWChange'
    )
  }

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 60, unit: 'MINUTES')
  }

  // groovylint-disable GStringExpressionWithinString
  environment {
    TF_INPUT                  = 'false'
    TF_IN_AUTOMATION          = 'true'
    TF_DIR                    = 'terraform'
    RESOURCE_GROUP_NAME_CRED  = credentials("${params.ENV}-apim-rg-name")
    APIM_NAME_CRED            = credentials("${params.ENV}-apim-apim-name")
    ARM_SUBSCRIPTION_ID        = credentials("${params.ENV}-apim-azure-subscription-id")
    ARM_CLIENT_ID              = credentials("${params.ENV}-apim-azure-client")
    ARM_CLIENT_SECRET          = credentials("${params.ENV}-apim-azure-secret")
    ARM_TENANT_ID              = credentials("${params.ENV}-apim-azure-tenant")
  }
  // groovylint-enable GStringExpressionWithinString

  stages {
    stage('Preflight: Tooling') {
      steps {
        sh '''
          #!/usr/bin/env bash
          set -e
          echo "[Preflight] Checking required tools..."

          if ! command -v docker >/dev/null 2>&1 && ! command -v node >/dev/null 2>&1; then
            echo "ERROR: Need Docker or Node to run Redocly CLI."
            exit 1
          fi

          if ! command -v terraform >/dev/null 2>&1; then
            echo "ERROR: Terraform not installed."
            exit 1
          fi

          echo "[Preflight] OK"
        '''
      }
    }

    stage('Resolve ENV & Credentials') {
      steps {
        script {
          env.TF_ENV = params.ENV?.trim() ?: (env.BRANCH_NAME == 'main' ? 'prod' : 'stage')
          env.BACKEND_TFVARS = "backend-${env.TF_ENV}.tfvars"
          echo "Selected ENV: ${env.TF_ENV}"
          echo "Backend config file: ${env.BACKEND_TFVARS}"
          echo "Change management enabled: ${env.TF_ENV == 'prod'}"
        }
      }
    }

    stage('Checkout') {
      steps {
        checkout scm
        sh '''
          #!/usr/bin/env bash
          set -e
          echo "Repo root:" && ls -la
          echo ""
          echo "API dir:" && ls -la api || true
        '''
      }
    }

    stage('Change Information') {
      parallel {
        stage('Get Existing Change Ticket') {
          agent none
          options { skipDefaultCheckout() }
          when { expression { params.CreateCAB != 'Yes' && params.Change?.trim() } }
          steps {
            script {
              getSNOWChange(params.Change)
            }
          }
        }
        stage('Create Change Request') {
          agent none
          options { skipDefaultCheckout() }
          when { expression { params.CreateCAB == 'Yes' } }
          steps {
            script {
              createSNOWChange(params.SNOW_SERVICE_NAME, params.ChangeType)
            }
          }
        }
      }
    }

    stage('Update Change Ticket') {
      agent none
      options { skipDefaultCheckout() }
      when { expression { env.SYS_ID != '' && env.SYS_ID != null } }
      steps {
        script {
          def changeLogDesc = getSCMChanges()

          def prevChangeLogDesc = ''
          def prevChanges = (env.CHANGE_DESC ?: '').split('\\n')
          for (int j = 0; j < prevChanges.length; j++) {
            if (prevChanges[j] != '\\n') {
              prevChangeLogDesc = prevChangeLogDesc + prevChanges[j] + '\\n'
            }
          }

          def payload = '''{
               "description": "''' + prevChangeLogDesc + changeLogDesc + '''"
          }'''

          updateSNOWChange(payload, 'updateDesc')
        }
      }
    }

    stage('Bundle OpenAPI (multi-API)') {
      steps {
        sh '''
          #!/usr/bin/env bash
          set -e

          mkdir -p build/api-bundled

          # Bundle only files like "My API v1.yaml" (space ' v' then version)
          for f in api/*\\ v*.yaml; do
            [ -f "$f" ] || continue

            base="$(basename "$f")"
            echo "[Bundle] Processing $f"

            if command -v docker >/dev/null 2>&1; then
              docker run --rm -v "$PWD":/spec redocly/cli \
                bundle "$f" --ext yaml -o "build/api-bundled/$base"
            else
              npx -y @redocly/cli@latest \
                bundle "$f" --ext yaml -o "build/api-bundled/$base"
            fi
          done
          # Best effort only: some agents/containers do not allow chown.
          if command -v chown >/dev/null 2>&1 && chown -R jenkins:jenkins build/ 2>/dev/null; then
            echo "[Bundle] Ownership updated to jenkins:jenkins"
          else
            echo "[Bundle] Skipping chown (not supported/allowed on this agent)"
          fi
          echo "[Bundle] Results:"
          ls -la build/api-bundled
        '''
      }
    }

    stage('Bundle validation (Redocly)') {
      steps {
        sh '''
          #!/usr/bin/env bash
          set -euo pipefail

          SPECS_LIST_FILE="$(mktemp)"
          find build/api-bundled -maxdepth 1 -type f -name "* v*.yaml" -print0 > "${SPECS_LIST_FILE}"

          if [ ! -s "${SPECS_LIST_FILE}" ]; then
            echo "ERROR: No bundled specs found in build/api-bundled"
            exit 1
          fi

          count=$(xargs -0 -n1 printf '%s\n' < "${SPECS_LIST_FILE}" | wc -l | xargs)
          echo "[Lint] Running Redocly against ${count} bundled spec(s)"

          if command -v docker >/dev/null 2>&1; then
            xargs -0 docker run --rm -w /spec -v "$PWD":/spec redocly/cli \
              lint --config redocly.yaml --format json < "${SPECS_LIST_FILE}" \
              | tee redocly-report.json
          else
            xargs -0 npx -y @redocly/cli@latest \
              lint --config redocly.yaml --format json < "${SPECS_LIST_FILE}" \
              | tee redocly-report.json
          fi

          rm -f "${SPECS_LIST_FILE}"
        '''
      }
      post {
        always {
          archiveArtifacts artifacts: 'redocly-report.json', allowEmptyArchive: true
        }
      }
    }

    stage('Production Gate') {
      agent none
      options { skipDefaultCheckout() }
      when { expression { env.TF_ENV == 'prod' } }
      steps {
        timeout(time: 10, unit: 'MINUTES') {
          script {
            if (env.CHANGE_STATE == '' || env.CHANGE_STATE == null || env.CHANGE_STATE.toInteger() < -2) {
              def approvalMap = input id: 'prod_gate',
                message: 'Change request not found or not approved by CAB',
                parameters: [
                text(description: 'Approved ServiceNow change ID.', name: 'ChangeRequest'),
                choice(
                  description: 'Type of change being pushed.',
                  choices: 'CAB Approved\nEmergency',
                  name: 'ChangeApprovalType'
                )
              ], ok: 'Proceed?', submitter: 'authenticated', submitterParameter: 'APPROVER'
              env.PROD_APPROVER = approvalMap['APPROVER']
              env.CHANGE_TYPE = approvalMap['ChangeApprovalType']
              env.CHANGE_ID = approvalMap['ChangeRequest']
            } else {
              env.PROD_APPROVER = env.BUILD_USER ?: 'jenkins'
              env.CHANGE_TYPE = 'CAB Approved'
              env.CHANGE_ID = params.Change
            }
          }
        }
      }
    }

    stage('Terraform Init/Validate') {
      steps {
        sh '''
          set -e

          echo "[Init] Using TF_DIR=${TF_DIR}"
          terraform -chdir="${TF_DIR}" init -reconfigure -backend-config="${BACKEND_TFVARS}" -input=false -no-color

          set +e
          FMT_OUTPUT=$(terraform -chdir="${TF_DIR}" fmt -check -diff -recursive -no-color 2>&1)
          FMT_STATUS=$?
          set -e
          if [ "${FMT_STATUS}" -ne 0 ]; then
            echo "[Terraform] fmt issues detected:"
            echo "${FMT_OUTPUT}"
            exit ${FMT_STATUS}
          fi

          terraform -chdir="${TF_DIR}" validate -no-color
        '''
      }
    }

    stage('Terraform Plan') {
      steps {
        sh '''
          #!/usr/bin/env bash
          set -e

          terraform -chdir="${TF_DIR}" plan -input=false -no-color \
            -var="resource_group_name=${RESOURCE_GROUP_NAME_CRED}" \
            -var="api_management_name=${APIM_NAME_CRED}" \
            -out=tfplan.out

          PLAN_FILE_PATH="${TF_DIR}/tfplan.out"
          if [ ! -f "${PLAN_FILE_PATH}" ]; then
            echo "ERROR: Plan command finished but plan file missing at ${PLAN_FILE_PATH}"
            exit 1
          fi
          echo "[Plan] Plan file created at ${PLAN_FILE_PATH}"
        '''
      }
      post {
        always {
          archiveArtifacts artifacts: "${TF_DIR}/tfplan.out", fingerprint: true, allowEmptyArchive: false
        }
      }
    }

    stage('Start Implementation') {
      agent { label 'dev' }
      options { skipDefaultCheckout() }
      when { expression { env.SYS_ID != '' && env.SYS_ID != null } }
      steps {
        script {
          updateSNOWChange('', 'implement')
          sleep(time: 5, unit: 'SECONDS')
          getSNOWChangeTask('Implement')

          def payload = """{
            \"description\": \"Implementation triggered via Jenkins Pipeline -
            ${env.JOB_BASE_NAME}:${env.BUILD_NUMBER}\"
          }"""

          updateSNOWChangeTask(payload, 'start')
        }
      }
    }

    stage('Terraform Apply') {
      steps {
        sh '''
          #!/usr/bin/env bash
          set -e

          PLAN_FILE="tfplan.out"
          PLAN_FILE_PATH="${TF_DIR}/${PLAN_FILE}"
          echo "[Apply] Workspace: $(pwd)"
          echo "[Apply] TF_DIR=${TF_DIR}"
          echo "[Apply] Expecting plan at ${PLAN_FILE_PATH}"
          if [ ! -f "${PLAN_FILE_PATH}" ]; then
            echo "ERROR: Plan file not found at ${PLAN_FILE_PATH}"
            ls -la "${TF_DIR}" || true
            exit 1
          fi

          echo "[Apply] Applying plan..."
          if ! terraform -chdir="${TF_DIR}" apply -input=false -no-color -auto-approve "${PLAN_FILE}"; then
            echo "ERROR: Apply failed. Automatic targeted rollback is disabled by policy."
            echo "Please perform controlled manual recovery using approved runbook."
            exit 1
          fi

          echo "[Apply] Deployment successful"
        '''
      }
    }

    stage('Post Implementation') {
      agent { label 'dev' }
      options { skipDefaultCheckout() }
      when { expression { env.SYS_ID != '' && env.SYS_ID != null } }
      steps {
        script {
          getSNOWChangeTask('Post%20implementation%20testing')

          def payload = '''{
               "description": "Post implementation triggered via Jenkins Pipeline - ''' + env.JOB_BASE_NAME + '''"
          }'''
          updateSNOWChangeTask(payload, 'start')

          payload = """{
            \"close_notes\": \"Post implementation completed successfully via Jenkins Pipeline -
            ${env.JOB_BASE_NAME}:${env.BUILD_NUMBER}\"
          }"""
          updateSNOWChangeTask(payload, 'close')

          payload = """{
            \"close_notes\": \"Change completed successfully via Jenkins Pipeline -
            ${env.JOB_BASE_NAME}:${env.BUILD_NUMBER}\"
          }"""
          updateSNOWChange(payload, 'close')
        }
      }
    }
  }

  post {
    success { echo "Build succeeded. ${BUILD_URL}" }
    failure { echo "Build failed: ${BUILD_URL}" }
    always {
      sh '''
        find . -name "tfplan.out" -delete
        echo "[Cleanup] Removed tfplan files"
      '''
    }
  }
}
