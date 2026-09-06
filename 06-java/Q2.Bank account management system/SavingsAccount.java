public class SavingsAccount extends BankAccount
{
    private double interestRate;

    public SavingsAccount(String accountNumber, double initialBalance, double interestRate)
    {
        super(accountNumber, initialBalance);
        this.interestRate = interestRate;
    }

    public void applyInterest()
    {
        double interest = getBalance() * (interestRate/100); // 이자율이 %단위 일 경우로 생각해서 100을 나눔
        deposit(interest);
    }
}
