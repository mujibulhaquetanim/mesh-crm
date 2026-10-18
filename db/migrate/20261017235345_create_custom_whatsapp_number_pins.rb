class CreateCustomWhatsappNumberPins < ActiveRecord::Migration[7.2]
  # Fork-only: the last two-step verification PIN this installation set on each
  # WhatsApp number, kept after the channel is gone.
  #
  # Upstream stores the PIN only in `channel_whatsapp.provider_config`, and
  # deleting a WhatsApp inbox deregisters the number at Meta while Meta keeps
  # its PIN. Re-adding the number then fails `/register` with (#133005) PIN
  # Mismatch, and Meta refuses to set a new PIN on a number that is not
  # registered (#133010), so nothing but a manual "turn off two-step
  # verification" in WhatsApp Manager could recover it. See
  # custom/app/models/custom/whatsapp_number_pin.rb.
  #
  # `pin` is written through Active Record encryption (`encrypts :pin`), so the
  # column holds ciphertext; it is a string because a PIN can start with 0.
  def change
    create_table :custom_whatsapp_number_pins do |t|
      t.string :phone_number_id, null: false
      t.string :pin, null: false

      t.timestamps
    end
    add_index :custom_whatsapp_number_pins, :phone_number_id, unique: true
  end
end
