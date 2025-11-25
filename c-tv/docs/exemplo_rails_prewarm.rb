#!/usr/bin/env ruby
# frozen_string_literal: true

# Exemplo prático de integração C-TV Prewarm com Ruby on Rails
# Copie os trechos relevantes para seu projeto

require 'httparty'
require 'active_support/all'

# =============================================================================
# 1. SERVICE OBJECT - app/services/ctv_prewarm_service.rb
# =============================================================================

class CtvPrewarmService
  include HTTParty
  base_uri ENV.fetch('CTV_BASE_URL', 'https://c-tv.saude.pi.gov.br')

  class << self
    # Pré-aquece áudio para um único paciente
    def prewarm_patient(patient_name, voice: nil)
      return false if patient_name.blank?

      payload = build_payload(patient_name, voice)
      response = send_prewarm_request(payload)

      handle_response(response, patient_name)
    rescue StandardError => e
      log_error("Erro ao pré-aquecer '#{patient_name}'", e)
      false
    end

    # Pré-aquece múltiplos pacientes com rate limiting
    def prewarm_batch(patient_names, voice: nil, delay: 0.1)
      results = { success: 0, failed: 0, skipped: 0 }

      patient_names.each do |name|
        if name.blank?
          results[:skipped] += 1
          next
        end

        if prewarm_patient(name, voice: voice)
          results[:success] += 1
        else
          results[:failed] += 1
        end

        sleep(delay) # Rate limiting
      end

      log_batch_results(results)
      results
    end

    # Verifica se o serviço está disponível
    def health_check
      response = get('/health', timeout: 5)
      response.code == 200
    rescue StandardError
      false
    end

    private

    def build_payload(patient_name, voice)
      payload = { text: patient_name }
      payload[:voice] = voice if voice.present?
      payload
    end

    def send_prewarm_request(payload)
      post('/prewarm',
        query: { key: api_key },
        body: payload.to_json,
        headers: { 'Content-Type' => 'application/json' },
        timeout: 5
      )
    end

    def api_key
      @api_key ||= begin
        key = ENV['CTV_API_KEY'] || Rails.application.credentials.dig(:ctv, :api_key)
        raise 'CTV_API_KEY não configurada' if key.blank?
        key
      end
    end

    def handle_response(response, patient_name)
      case response.code
      when 202
        log_info("✅ Pré-aquecimento iniciado: #{patient_name}")
        true
      when 401
        log_error("❌ Não autorizado. Verifique CTV_API_KEY", nil)
        false
      when 400
        log_error("❌ Request inválido para '#{patient_name}': #{response.body}", nil)
        false
      else
        log_warn("⚠️ Status inesperado #{response.code}: #{patient_name}")
        false
      end
    end

    def log_info(message)
      Rails.logger.info("[CTV Prewarm] #{message}")
    end

    def log_warn(message)
      Rails.logger.warn("[CTV Prewarm] #{message}")
    end

    def log_error(message, exception)
      msg = "[CTV Prewarm] #{message}"
      msg += " - #{exception.class}: #{exception.message}" if exception
      Rails.logger.error(msg)
    end

    def log_batch_results(results)
      log_info("Lote concluído - Sucesso: #{results[:success]}, " \
               "Falhas: #{results[:failed]}, Ignorados: #{results[:skipped]}")
    end
  end
end

# =============================================================================
# 2. BACKGROUND JOBS
# =============================================================================

# app/jobs/prewarm_patient_audio_job.rb
class PrewarmPatientAudioJob < ApplicationJob
  queue_as :low_priority
  retry_on HTTParty::Error, wait: :polynomially_longer, attempts: 3

  def perform(patient_name, voice: nil)
    return unless patient_name.present?

    CtvPrewarmService.prewarm_patient(patient_name, voice: voice)
  end
end

# app/jobs/prewarm_batch_job.rb
class PrewarmBatchJob < ApplicationJob
  queue_as :low_priority
  retry_on StandardError, wait: 30.seconds, attempts: 2

  def perform(patient_names, voice: nil)
    CtvPrewarmService.prewarm_batch(patient_names, voice: voice)
  end
end

# =============================================================================
# 3. MODEL COM CALLBACKS
# =============================================================================

# app/models/patient.rb
class Patient < ApplicationRecord
  # Callbacks para pré-aquecimento automático
  after_create :schedule_prewarm_audio
  after_update :schedule_prewarm_audio, if: :saved_change_to_name?

  # Validações
  validates :name, presence: true, length: { minimum: 3, maximum: 100 }

  # Associações
  has_many :appointments
  has_many :call_logs

  private

  def schedule_prewarm_audio
    # Usar background job para não bloquear o cadastro
    PrewarmPatientAudioJob.perform_later(name)
  end
end

# =============================================================================
# 4. CONTROLLER COM PRÉ-AQUECIMENTO
# =============================================================================

# app/controllers/patients_controller.rb
class PatientsController < ApplicationController
  before_action :set_patient, only: [:show, :edit, :update, :destroy]

  # POST /patients
  def create
    @patient = Patient.new(patient_params)

    respond_to do |format|
      if @patient.save
        # Pré-aquecimento é automático via callback do model
        format.html { redirect_to @patient, notice: 'Paciente cadastrado com sucesso.' }
        format.json { render :show, status: :created, location: @patient }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @patient.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /patients/1
  def update
    respond_to do |format|
      if @patient.update(patient_params)
        # Se nome mudou, callback automaticamente pré-aquece novo áudio
        format.html { redirect_to @patient, notice: 'Paciente atualizado com sucesso.' }
        format.json { render :show, status: :ok, location: @patient }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @patient.errors, status: :unprocessable_entity }
      end
    end
  end

  # POST /patients/import
  def import
    file = params[:file]
    return redirect_to patients_path, alert: 'Arquivo não fornecido' unless file

    patients = import_patients_from_csv(file)

    if patients.any?
      # Pré-aquecer todos os nomes em lote (background)
      patient_names = patients.pluck(:name)
      PrewarmBatchJob.perform_later(patient_names)

      redirect_to patients_path, notice: "#{patients.count} pacientes importados. Áudios sendo preparados..."
    else
      redirect_to patients_path, alert: 'Nenhum paciente válido encontrado no arquivo.'
    end
  end

  private

  def set_patient
    @patient = Patient.find(params[:id])
  end

  def patient_params
    params.require(:patient).permit(:name, :cpf, :date_of_birth, :phone)
  end

  def import_patients_from_csv(file)
    patients = []
    CSV.foreach(file.path, headers: true) do |row|
      patient = Patient.create(
        name: row['nome'],
        cpf: row['cpf'],
        date_of_birth: row['data_nascimento']
      )
      patients << patient if patient.persisted?
    end
    patients
  end
end

# =============================================================================
# 5. RAKE TASKS PARA PRÉ-AQUECIMENTO EM LOTE
# =============================================================================

# lib/tasks/ctv.rake
namespace :ctv do
  desc 'Pré-aquece áudios de todos os pacientes cadastrados'
  task prewarm_all: :environment do
    puts "Buscando pacientes..."
    patient_names = Patient.pluck(:name)

    puts "Pré-aquecendo #{patient_names.count} pacientes..."
    results = CtvPrewarmService.prewarm_batch(patient_names)

    puts "\n=== Resultado ==="
    puts "Sucesso: #{results[:success]}"
    puts "Falhas: #{results[:failed]}"
    puts "Ignorados: #{results[:skipped]}"
  end

  desc 'Pré-aquece áudios de pacientes com consultas agendadas para hoje'
  task prewarm_today: :environment do
    puts "Buscando consultas de hoje..."
    patients = Appointment.today.includes(:patient).map(&:patient).uniq

    puts "Pré-aquecendo #{patients.count} pacientes..."
    results = CtvPrewarmService.prewarm_batch(patients.pluck(:name))

    puts "\n=== Resultado ==="
    puts "Sucesso: #{results[:success]}"
    puts "Falhas: #{results[:failed]}"
  end

  desc 'Pré-aquece áudios de pacientes com consultas agendadas para amanhã'
  task prewarm_tomorrow: :environment do
    puts "Buscando consultas de amanhã..."
    patients = Appointment.tomorrow.includes(:patient).map(&:patient).uniq

    puts "Pré-aquecendo #{patients.count} pacientes..."
    results = CtvPrewarmService.prewarm_batch(patients.pluck(:name))

    puts "\n=== Resultado ==="
    puts "Sucesso: #{results[:success]}"
    puts "Falhas: #{results[:failed]}"
  end

  desc 'Verifica saúde do serviço C-TV'
  task health_check: :environment do
    puts "Verificando C-TV em #{ENV['CTV_BASE_URL']}..."
    if CtvPrewarmService.health_check
      puts "✅ Serviço C-TV está disponível"
      exit 0
    else
      puts "❌ Serviço C-TV está indisponível"
      exit 1
    end
  end
end

# =============================================================================
# 6. AGENDAMENTO COM WHENEVER
# =============================================================================

# config/schedule.rb
set :output, 'log/cron.log'
set :environment, ENV['RAILS_ENV'] || 'production'

# Pré-aquecer pacientes do próximo dia às 2h da manhã
every 1.day, at: '2:00 AM' do
  rake 'ctv:prewarm_tomorrow'
end

# Pré-aquecer pacientes do dia às 6h da manhã (reforço)
every 1.day, at: '6:00 AM' do
  rake 'ctv:prewarm_today'
end

# Health check a cada 5 minutos
every 5.minutes do
  rake 'ctv:health_check'
end

# =============================================================================
# 7. TESTES RSPEC
# =============================================================================

# spec/services/ctv_prewarm_service_spec.rb
require 'rails_helper'

RSpec.describe CtvPrewarmService do
  let(:base_url) { ENV['CTV_BASE_URL'] }
  let(:api_key) { ENV['CTV_API_KEY'] }
  let(:patient_name) { 'João Silva Santos' }

  describe '.prewarm_patient' do
    context 'quando requisição é bem-sucedida' do
      before do
        stub_request(:post, "#{base_url}/prewarm")
          .with(
            query: { key: api_key },
            body: { text: patient_name }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
          .to_return(
            status: 202,
            body: {
              message: 'Pré-aquecimento iniciado',
              text: patient_name,
              status: 'processing'
            }.to_json
          )
      end

      it 'retorna true' do
        expect(described_class.prewarm_patient(patient_name)).to be_truthy
      end

      it 'envia requisição POST com payload correto' do
        described_class.prewarm_patient(patient_name)
        expect(WebMock).to have_requested(:post, "#{base_url}/prewarm")
          .with(body: { text: patient_name }.to_json)
      end
    end

    context 'quando API key é inválida' do
      before do
        stub_request(:post, "#{base_url}/prewarm")
          .to_return(status: 401, body: 'Acesso negado')
      end

      it 'retorna false' do
        expect(described_class.prewarm_patient(patient_name)).to be_falsey
      end
    end

    context 'quando nome é vazio' do
      it 'retorna false sem fazer requisição' do
        expect(described_class.prewarm_patient('')).to be_falsey
        expect(WebMock).not_to have_requested(:post, "#{base_url}/prewarm")
      end
    end
  end

  describe '.prewarm_batch' do
    let(:patient_names) { ['João Silva', 'Maria Santos', 'Pedro Oliveira'] }

    before do
      stub_request(:post, "#{base_url}/prewarm")
        .to_return(status: 202)
    end

    it 'pré-aquece todos os nomes' do
      results = described_class.prewarm_batch(patient_names)
      expect(results[:success]).to eq(3)
      expect(WebMock).to have_requested(:post, "#{base_url}/prewarm").times(3)
    end
  end

  describe '.health_check' do
    context 'quando serviço está disponível' do
      before do
        stub_request(:get, "#{base_url}/health")
          .to_return(status: 200, body: { status: 'ok' }.to_json)
      end

      it 'retorna true' do
        expect(described_class.health_check).to be_truthy
      end
    end

    context 'quando serviço está indisponível' do
      before do
        stub_request(:get, "#{base_url}/health").to_timeout
      end

      it 'retorna false' do
        expect(described_class.health_check).to be_falsey
      end
    end
  end
end

# spec/jobs/prewarm_patient_audio_job_spec.rb
require 'rails_helper'

RSpec.describe PrewarmPatientAudioJob, type: :job do
  let(:patient_name) { 'Maria Santos' }

  it 'enfileira job na fila low_priority' do
    expect {
      PrewarmPatientAudioJob.perform_later(patient_name)
    }.to have_enqueued_job(PrewarmPatientAudioJob)
      .with(patient_name)
      .on_queue('low_priority')
  end

  it 'chama CtvPrewarmService.prewarm_patient' do
    allow(CtvPrewarmService).to receive(:prewarm_patient)

    PrewarmPatientAudioJob.perform_now(patient_name)

    expect(CtvPrewarmService).to have_received(:prewarm_patient)
      .with(patient_name, voice: nil)
  end
end

# spec/models/patient_spec.rb
require 'rails_helper'

RSpec.describe Patient, type: :model do
  describe 'callbacks' do
    it 'agenda pré-aquecimento após criar paciente' do
      expect {
        create(:patient, name: 'João Silva')
      }.to have_enqueued_job(PrewarmPatientAudioJob)
    end

    it 'agenda pré-aquecimento após atualizar nome' do
      patient = create(:patient, name: 'João Silva')

      expect {
        patient.update(name: 'João Santos Silva')
      }.to have_enqueued_job(PrewarmPatientAudioJob)
    end

    it 'não agenda pré-aquecimento ao atualizar outros campos' do
      patient = create(:patient, name: 'João Silva')

      expect {
        patient.update(phone: '85999999999')
      }.not_to have_enqueued_job(PrewarmPatientAudioJob)
    end
  end
end

# =============================================================================
# 8. SCRIPT DE TESTE STANDALONE (SEM RAILS)
# =============================================================================

# test_prewarm.rb
require 'httparty'
require 'json'

BASE_URL = 'https://c-tv.saude.pi.gov.br'
API_KEY = 'e38cade885ddd37895267ba0ff210551'

def prewarm_audio(patient_name)
  response = HTTParty.post(
    "#{BASE_URL}/prewarm",
    query: { key: API_KEY },
    body: { text: patient_name }.to_json,
    headers: { 'Content-Type' => 'application/json' },
    timeout: 5
  )

  case response.code
  when 202
    puts "✅ Pré-aquecimento iniciado: #{patient_name}"
    true
  when 401
    puts "❌ Não autorizado. Verifique API_KEY"
    false
  else
    puts "⚠️ Status inesperado: #{response.code}"
    false
  end
rescue StandardError => e
  puts "❌ Erro: #{e.message}"
  false
end

# Teste
if __FILE__ == $PROGRAM_NAME
  patients = [
    'Antonio Pereira de Sousa',
    'Maria da Silva Santos',
    'José Carlos Oliveira'
  ]

  puts "Testando pré-aquecimento de #{patients.count} pacientes...\n\n"

  patients.each do |name|
    prewarm_audio(name)
    sleep 0.5
  end

  puts "\nTeste concluído!"
end
