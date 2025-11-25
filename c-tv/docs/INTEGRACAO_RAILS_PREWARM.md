# Integração Ruby on Rails - Pré-aquecimento de Áudio C-TV

## Visão Geral

O sistema C-TV oferece um endpoint de **pré-aquecimento de cache** (`/prewarm`) que permite gerar áudios de forma assíncrona **antes** de serem necessários na chamada de pacientes. Isso elimina a latência de 6-10 segundos da síntese de voz quando o paciente é efetivamente chamado.

### Quando Usar

✅ **Recomendado:**
- Ao **cadastrar** um novo paciente na fila
- Ao **atualizar** o nome de um paciente
- Ao **importar** lotes de pacientes
- Em **horários de baixa demanda** (madrugada) para pré-gerar áudios do dia seguinte

❌ **NÃO recomendado:**
- Durante a chamada do paciente (use `/speak` diretamente)
- Para textos genéricos que não são nomes de pacientes
- Em requisições síncronas que precisam de resposta imediata

## Endpoint de Pré-aquecimento

### URL
```
POST https://c-tv.saude.pi.gov.br/prewarm?key=API_KEY
```

### Autenticação
Query parameter `key` com a chave API do C-TV (mesma chave usada no `/speak`)

### Request Body (JSON)
```json
{
  "text": "Antonio Pereira de Sousa",
  "voice": "coqui_xtts_v2_cloned"  // opcional
}
```

### Response (HTTP 202 Accepted)
```json
{
  "message": "Pré-aquecimento iniciado",
  "text": "Antonio Pereira de Sousa",
  "voice": "coqui_xtts_v2_cloned",
  "status": "processing",
  "timestamp": null
}
```

### Comportamento
- **Assíncrono**: A requisição retorna imediatamente (HTTP 202)
- **Background**: A síntese acontece em segundo plano no servidor C-TV
- **Idempotente**: Se o áudio já existe em cache, ignora silenciosamente
- **TTL do Cache**: 60 minutos (configurável via `CACHE_TTL_MINUTES`)

## Integração Ruby on Rails

### 1. Service Object (Recomendado)

Crie um service object para encapsular a lógica de integração:

```ruby
# app/services/ctv_prewarm_service.rb
class CtvPrewarmService
  include HTTParty
  base_uri ENV.fetch('CTV_BASE_URL', 'https://c-tv.saude.pi.gov.br')

  class << self
    # Pré-aquece áudio para um paciente
    def prewarm_patient(patient_name, voice: nil)
      return if patient_name.blank?

      payload = { text: patient_name }
      payload[:voice] = voice if voice.present?

      response = post('/prewarm',
        query: { key: api_key },
        body: payload.to_json,
        headers: { 'Content-Type' => 'application/json' },
        timeout: 5 # timeout curto, pois é assíncrono
      )

      handle_response(response, patient_name)
    rescue HTTParty::Error, Timeout::Error => e
      Rails.logger.error "[CTV Prewarm] Erro ao pré-aquecer '#{patient_name}': #{e.message}"
      false
    end

    # Pré-aquece múltiplos pacientes em lote
    def prewarm_batch(patient_names, voice: nil)
      patient_names.each do |name|
        prewarm_patient(name, voice: voice)
        sleep 0.1 # pequeno delay para não sobrecarregar
      end
    end

    private

    def api_key
      ENV.fetch('CTV_API_KEY') do
        raise 'CTV_API_KEY não configurada. Configure em .env ou credentials'
      end
    end

    def handle_response(response, patient_name)
      case response.code
      when 202
        Rails.logger.info "[CTV Prewarm] ✅ Iniciado: #{patient_name}"
        true
      when 401
        Rails.logger.error "[CTV Prewarm] ❌ Não autorizado. Verifique CTV_API_KEY"
        false
      when 400
        Rails.logger.error "[CTV Prewarm] ❌ Request inválido: #{response.body}"
        false
      else
        Rails.logger.warn "[CTV Prewarm] ⚠️ Status inesperado #{response.code}: #{patient_name}"
        false
      end
    end
  end
end
```

### 2. Uso em Models (Callbacks)

```ruby
# app/models/patient.rb
class Patient < ApplicationRecord
  after_create :prewarm_audio_cache
  after_update :prewarm_audio_cache, if: :saved_change_to_name?

  private

  def prewarm_audio_cache
    CtvPrewarmService.prewarm_patient(name)
  end
end
```

### 3. Uso em Background Jobs (Recomendado para Produção)

```ruby
# app/jobs/prewarm_patient_audio_job.rb
class PrewarmPatientAudioJob < ApplicationJob
  queue_as :low_priority # fila de baixa prioridade
  retry_on HTTParty::Error, wait: :polynomially_longer, attempts: 3

  def perform(patient_name, voice: nil)
    CtvPrewarmService.prewarm_patient(patient_name, voice: voice)
  end
end

# Uso:
PrewarmPatientAudioJob.perform_later(patient.name)
```

### 4. Uso em Controllers

```ruby
# app/controllers/patients_controller.rb
class PatientsController < ApplicationController
  def create
    @patient = Patient.new(patient_params)

    if @patient.save
      # Pré-aquecer áudio em background (não bloqueia a resposta)
      PrewarmPatientAudioJob.perform_later(@patient.name)

      redirect_to @patient, notice: 'Paciente cadastrado com sucesso.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  def import
    patients = PatientImportService.import(params[:file])

    # Pré-aquecer todos os nomes em lote
    patient_names = patients.pluck(:name)
    PrewarmBatchJob.perform_later(patient_names)

    redirect_to patients_path, notice: "#{patients.count} pacientes importados."
  end
end
```

### 5. Background Job para Lotes

```ruby
# app/jobs/prewarm_batch_job.rb
class PrewarmBatchJob < ApplicationJob
  queue_as :low_priority

  def perform(patient_names)
    CtvPrewarmService.prewarm_batch(patient_names)
  end
end
```

## Configuração

### 1. Adicionar Variáveis de Ambiente

```bash
# .env (development)
CTV_BASE_URL=https://c-tv.saude.pi.gov.br
CTV_API_KEY=e38cade885ddd37895267ba0ff210551
```

```ruby
# config/credentials.yml.enc (production)
ctv:
  base_url: https://c-tv.saude.pi.gov.br
  api_key: <%= ENV['CTV_API_KEY'] %>
```

### 2. Instalar HTTParty

```ruby
# Gemfile
gem 'httparty', '~> 0.21'
```

```bash
bundle install
```

### 3. Configurar Background Jobs (Sidekiq recomendado)

```ruby
# config/sidekiq.yml
:queues:
  - default
  - low_priority  # para jobs de pré-aquecimento
```

## Estratégias de Pré-aquecimento

### Estratégia 1: Real-time (Cadastro Individual)
```ruby
# Pré-aquecer imediatamente ao cadastrar
after_create :prewarm_audio_cache
```
**Prós:** Áudio pronto rapidamente
**Contras:** Pequeno overhead no cadastro

### Estratégia 2: Background Job (Recomendado)
```ruby
# Pré-aquecer via job assíncrono
after_create { PrewarmPatientAudioJob.perform_later(name) }
```
**Prós:** Não bloqueia cadastro, resiliente a falhas
**Contras:** Pequeno delay até áudio ficar pronto

### Estratégia 3: Batch Noturno
```ruby
# lib/tasks/prewarm.rake
namespace :ctv do
  desc "Pré-aquece áudios de pacientes para o próximo dia"
  task prewarm_tomorrow: :environment do
    # Pacientes com consultas agendadas para amanhã
    patients = Appointment.tomorrow.includes(:patient).map(&:patient)

    puts "Pré-aquecendo #{patients.count} pacientes..."
    CtvPrewarmService.prewarm_batch(patients.pluck(:name))
    puts "Concluído!"
  end
end
```
**Prós:** Não impacta horário de pico
**Contras:** Precisa agendar cron/whenever

```ruby
# config/schedule.rb (whenever gem)
every 1.day, at: '2:00 AM' do
  rake 'ctv:prewarm_tomorrow'
end
```

### Estratégia 4: Pré-aquecimento Condicional
```ruby
# Apenas para nomes longos (>20 caracteres) ou com acentos
def should_prewarm?
  name.length > 20 || name.match?(/[áàãâéêíóôõúç]/i)
end

after_create :prewarm_audio_cache, if: :should_prewarm?
```

## Monitoramento e Logs

### 1. Log de Pré-aquecimento

```ruby
# config/initializers/custom_logger.rb
CTV_LOGGER = ActiveSupport::Logger.new(
  Rails.root.join('log', 'ctv_prewarm.log'),
  level: Logger::INFO
)

# No service:
CTV_LOGGER.info "[Prewarm] #{patient_name} - Status: #{response.code}"
```

### 2. Métricas (Opcional)

```ruby
# app/services/ctv_prewarm_service.rb
def prewarm_patient(patient_name, voice: nil)
  start_time = Time.current

  # ... código de requisição ...

  duration = Time.current - start_time
  StatsD.increment('ctv.prewarm.requests')
  StatsD.histogram('ctv.prewarm.duration', duration)
end
```

## Boas Práticas

### ✅ DO (Faça)

1. **Use Background Jobs** para pré-aquecimento (não bloqueia usuário)
2. **Trate erros silenciosamente** (pré-aquecimento é otimização, não crítico)
3. **Configure timeout curto** (5 segundos) - response é imediata
4. **Valide texto antes de enviar** (não envie strings vazias)
5. **Use filas de baixa prioridade** para jobs de pré-aquecimento
6. **Implemente retry com backoff exponencial**
7. **Monitore taxa de sucesso** via logs/métricas

### ❌ DON'T (Não faça)

1. **NÃO bloqueie request HTTP do usuário** aguardando pré-aquecimento
2. **NÃO envie mesma requisição múltiplas vezes** (cache é idempotente)
3. **NÃO pré-aqueça textos genéricos** (ex: "Próximo paciente")
4. **NÃO sobrecarregue C-TV** com rajadas de requisições (use rate limiting)
5. **NÃO exponha API_KEY no frontend** (sempre backend)
6. **NÃO aguarde confirmação de síntese** (response 202 é suficiente)
7. **NÃO falhe cadastro se pré-aquecimento falhar** (é otimização, não requisito)

## Troubleshooting

### Problema: HTTP 401 Unauthorized
```
❌ Solução: Verifique se CTV_API_KEY está correta
```

### Problema: HTTP 400 Bad Request
```
❌ Causa: JSON inválido ou campo 'text' vazio
✅ Solução: Valide dados antes de enviar:
  - text não pode ser nil/blank
  - JSON deve ter Content-Type correto
```

### Problema: Timeout na requisição
```
❌ Causa: Servidor C-TV indisponível
✅ Solução:
  - Configure retry em background jobs
  - Verifique conectividade: curl https://c-tv.saude.pi.gov.br/health
```

### Problema: Áudio não está pronto quando chamado
```
❌ Causa: TTL de cache expirou (60 min) ou servidor reiniciou
✅ Solução:
  - Pré-aqueça mais próximo do horário de uso
  - Considere aumentar CACHE_TTL_MINUTES no C-TV
  - Use estratégia de batch noturno
```

### Problema: C-TV retorna 202 mas áudio não é gerado
```
❌ Causa: Erro no Coqui Server (verificar logs no Kubernetes)
✅ Solução:
  kubectl logs -n c-tv deployment/coqui-server --tail=100
  kubectl logs -n c-tv deployment/web --tail=100
```

## Testes Automatizados

### RSpec - Service Test

```ruby
# spec/services/ctv_prewarm_service_spec.rb
require 'rails_helper'

RSpec.describe CtvPrewarmService do
  describe '.prewarm_patient' do
    let(:patient_name) { 'João Silva' }

    before do
      stub_request(:post, "#{ENV['CTV_BASE_URL']}/prewarm")
        .with(
          query: { key: ENV['CTV_API_KEY'] },
          body: { text: patient_name }.to_json
        )
        .to_return(status: 202, body: { message: 'Pré-aquecimento iniciado' }.to_json)
    end

    it 'envia requisição de pré-aquecimento' do
      expect(described_class.prewarm_patient(patient_name)).to be_truthy
    end

    it 'retorna false para nome vazio' do
      expect(described_class.prewarm_patient('')).to be_falsey
    end
  end
end
```

### RSpec - Job Test

```ruby
# spec/jobs/prewarm_patient_audio_job_spec.rb
require 'rails_helper'

RSpec.describe PrewarmPatientAudioJob, type: :job do
  it 'enfileira job corretamente' do
    expect {
      PrewarmPatientAudioJob.perform_later('Maria Santos')
    }.to have_enqueued_job(PrewarmPatientAudioJob)
      .with('Maria Santos')
      .on_queue('low_priority')
  end
end
```

## Exemplo Completo - Fluxo de Cadastro

```ruby
# app/controllers/patients_controller.rb
class PatientsController < ApplicationController
  def create
    @patient = Patient.new(patient_params)

    ActiveRecord::Base.transaction do
      if @patient.save
        # 1. Pré-aquecer áudio (assíncrono, não bloqueia)
        PrewarmPatientAudioJob.perform_later(@patient.name)

        # 2. Adicionar à fila de atendimento
        @appointment = @patient.appointments.create!(
          scheduled_at: Time.current,
          status: :waiting
        )

        # 3. Responder ao usuário imediatamente
        redirect_to @appointment, notice: 'Paciente cadastrado e adicionado à fila.'
      else
        render :new, status: :unprocessable_entity
      end
    end
  end
end

# Quando chamar o paciente (minutos depois):
# app/services/call_patient_service.rb
class CallPatientService
  def self.call(patient, monitor)
    # Áudio JÁ ESTÁ EM CACHE (pré-aquecido no cadastro)
    # Chamada será instantânea (sem latência de síntese)
    audio_url = "#{ENV['CTV_BASE_URL']}/speak?key=#{ENV['CTV_API_KEY']}&texto=#{patient.name}"

    # Enviar via WebSocket para o monitor
    ActionCable.server.broadcast(
      "monitor_#{monitor.id}",
      {
        type: 'call_patient',
        patient_id: patient.id,
        patient_name: patient.name,
        audio_url: audio_url
      }
    )
  end
end
```

## Documentação Adicional

- **API C-TV Completa**: Consulte `/tts` endpoint para informações detalhadas
- **Health Check**: `GET /health` para verificar disponibilidade
- **Logs Kubernetes**:
  ```bash
  kubectl logs -n c-tv deployment/web -f
  kubectl logs -n c-tv deployment/coqui-server -f
  ```

## Suporte

Em caso de dúvidas ou problemas:
1. Verifique logs da aplicação Rails
2. Verifique logs do C-TV no Kubernetes
3. Teste endpoint `/health` do C-TV
4. Contate a equipe de infraestrutura

---

**Última atualização**: 25 de novembro de 2025
**Versão C-TV**: v0.03 SOLID
**Status**: ✅ Testado em Produção
